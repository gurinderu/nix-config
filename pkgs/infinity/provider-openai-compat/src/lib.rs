//! Infinity `ModelProvider` for any OpenAI-compatible Chat Completions
//! endpoint (llama.cpp `llama-server`, vLLM, Ollama, ...), configured by env:
//!
//! - `OPENAI_COMPAT_BASE_URL`   e.g. `http://127.0.0.1:8080/v1` (required)
//! - `OPENAI_COMPAT_MODEL`      upstream model name (default `local`)
//! - `OPENAI_COMPAT_API_KEY`    bearer token (default `none`)
//! - `OPENAI_COMPAT_CONTEXT`    context window in tokens (default 16384)
//! - `OPENAI_COMPAT_MAX_OUTPUT` max output tokens per request (default 4096)
//! - `OPENAI_COMPAT_DISPLAY`    display name (default = model)

use std::sync::Arc;

use async_trait::async_trait;
use futures_util::StreamExt;
use infinity_provider_protocol::{
    CompletionError, CompletionModel, CompletionRequest, ErrorClass, ModelEntry, ModelProvider,
    ModelStream, SingleModelProvider, StreamChunk, ToolCall, ToolCallDeltaContent,
};
use infinity_provider_rig::RigCompletionModel;
use rig::client::CompletionClient;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_owned())
}

/// rig 0.31's Chat Completions streaming path stringifies transport failures
/// into `CompletionError::ProviderError("Http client error: ...")`, which
/// `infinity-provider-rig` classifies as `Fatal` (it only maps the typed
/// `HttpError` variant to `Transient`). Re-classify them so the runtime retries.
fn reclassify(e: CompletionError) -> CompletionError {
    let msg = e.to_string();
    if matches!(e.class(), ErrorClass::Fatal)
        && (msg.contains("Http client error") || msg.contains("error sending request"))
    {
        return CompletionError::provider(ErrorClass::Transient, msg);
    }
    e
}

/// Put complete tool calls back into the order the model wrote them.
///
/// rig 0.31 accumulates streamed tool calls in a `HashMap<index, _>` and, at
/// `finish_reason: tool_calls`, emits the complete `ToolCall`s in hash order.
/// Infinity runs only the first `ToolCall` of a turn, so with parallel calls
/// a random one ran. The `ToolCallDelta::Name` chunks, though, are forwarded
/// as they stream, i.e. in index order; remember that order and hold back
/// each run of consecutive `ToolCall`s until it can be released sorted.
fn ordered_tool_calls(inner: ModelStream) -> ModelStream {
    Box::pin(async_stream::stream! {
        let mut inner = inner;
        let mut seen: Vec<String> = Vec::new();
        let mut held: Vec<ToolCall> = Vec::new();
        let rank = |seen: &[String], id: &str| seen.iter().position(|s| s == id).unwrap_or(usize::MAX);
        while let Some(item) = inner.next().await {
            match item {
                Ok(StreamChunk::ToolCall(call)) => held.push(call),
                other => {
                    // Stable sort: calls with an unseen id keep their order, last.
                    held.sort_by_key(|c| rank(&seen, &c.id));
                    for call in held.drain(..) {
                        yield Ok(StreamChunk::ToolCall(call));
                    }
                    if let Ok(StreamChunk::ToolCallDelta { id, content: ToolCallDeltaContent::Name(_) }) = &other
                        && !seen.contains(id)
                    {
                        seen.push(id.clone());
                    }
                    yield other;
                }
            }
        }
        held.sort_by_key(|c| rank(&seen, &c.id));
        for call in held {
            yield Ok(StreamChunk::ToolCall(call));
        }
    })
}

/// The rig-backed model with the two fixes above applied to its stream.
struct Fixed<M>(M);

#[async_trait]
impl<M: CompletionModel + Send + Sync> CompletionModel for Fixed<M> {
    async fn stream(&self, request: CompletionRequest) -> Result<ModelStream, CompletionError> {
        let s = self.0.stream(request).await.map_err(reclassify)?;
        Ok(ordered_tool_calls(Box::pin(
            s.map(|item| item.map_err(reclassify)),
        )))
    }
}

pub fn provider_from_env() -> Result<(Arc<dyn ModelProvider>, String), BoxError> {
    let base_url = std::env::var("OPENAI_COMPAT_BASE_URL")
        .map_err(|_| "OPENAI_COMPAT_BASE_URL is not set")?;
    let model = env_or("OPENAI_COMPAT_MODEL", "local");
    let api_key = env_or("OPENAI_COMPAT_API_KEY", "none");
    let context_window: usize = env_or("OPENAI_COMPAT_CONTEXT", "16384").parse()?;
    let max_output: u64 = env_or("OPENAI_COMPAT_MAX_OUTPUT", "4096").parse()?;

    // No idle keep-alive pooling: llama-server (cpp-httplib) closes
    // connections on its own schedule, and a stale pooled connection surfaces
    // as "error sending request". A fresh loopback connection costs nothing.
    let http = reqwest::Client::builder().pool_max_idle_per_host(0).build()?;

    // Chat Completions API (`/chat/completions`), not the Responses API that
    // rig's default `openai::Client` targets.
    let client = rig::providers::openai::CompletionsClient::<reqwest::Client>::builder()
        .http_client(http)
        .api_key(&api_key)
        .base_url(&base_url)
        .build()?;
    let rig_model = client.completion_model(&model);

    let entry = ModelEntry {
        model_id: model.clone(),
        display_name: env_or("OPENAI_COMPAT_DISPLAY", &model),
        context_window,
        max_output_tokens: Some(max_output),
        supports_image_input: false,
    };
    let provider = SingleModelProvider::new(entry, Fixed(RigCompletionModel::new(rig_model)));
    Ok((Arc::new(provider), model))
}
