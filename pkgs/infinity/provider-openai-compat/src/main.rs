//! Provider binary for the Infinity daemon (`~/.infinity/providers.json`):
//! serves the OpenAI-compatible model over infinity's Unix-socket provider
//! protocol and prints the socket path as the first stdout line.

use std::io::Write;

use infinity_provider_protocol::remote::serve_provider;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (provider, model) = infinity_provider_openai_compat::provider_from_env()?;
    let (socket_path, server) = serve_provider(provider)?;
    println!("{}", socket_path.display());
    std::io::stdout().flush()?;
    eprintln!("openai-compat provider serving model {model}");
    server.await;
    Ok(())
}
