#!/usr/bin/env python3
# Fabro <-> ollama tool-compat shim.
#
# WHY THIS EXISTS: Fabro's built-in "openai" provider (repointed at ollama, see
# fabro.nix) drives agent nodes through the OpenAI *Responses* API and always
# advertises its `apply_patch` file-edit tool as a FREEFORM tool
# (`"type":"custom"`). ollama's OpenAI-compat endpoint cannot parse that and
# rejects the WHOLE request with HTTP 500 "Unsupported tool type", so every
# agent stage fails before it can run a single tool (no bash -> no repo read ->
# no REVIEW-FINDINGS.md). `permissions`/`features` do not suppress the tool;
# the encoding is hardcoded in the provider. This shim sits in front of ollama
# and strips `type:"custom"` tool entries from /v1/* request bodies, leaving the
# regular function tools (shell/read_file/write_file/...) that ollama accepts.
# Everything else is a transparent pass-through, including streamed responses.
#
# It does NOT fix context size: that is set via OLLAMA_CONTEXT_LENGTH on the
# ollama service (night-llm.nix), because ollama ignores per-request num_ctx on
# the OpenAI path.
import http.server, socketserver, urllib.request, urllib.error, json, os, sys

UPSTREAM = os.environ.get("SHIM_UPSTREAM", "http://127.0.0.1:11434")
LISTEN_HOST = os.environ.get("SHIM_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SHIM_PORT", "11501"))
HOP = {"content-length", "host", "connection", "keep-alive", "transfer-encoding",
       "proxy-connection", "te", "trailer", "upgrade", "accept-encoding", "expect"}

def log(msg):
    print(msg, file=sys.stdout, flush=True)

def _summarize_messages(doc):
    # PII-safe shape summary of the chat request for diagnosing template-side
    # 400s (notably Qwen3's `raise_exception('No user query found in messages.')`,
    # which fires when the message array has NO genuine user turn left — only
    # system + <tool_response>-wrapped user turns. This happens when the prompt
    # nears num_ctx and ollama truncates the head, dropping the original goal).
    # Logs ONLY roles + a genuine-user flag — never message content, so repo
    # source and secrets never reach the journal.
    msgs = doc.get("messages")
    if not isinstance(msgs, list):
        return "messages: <none>"
    roles = []
    genuine_user = 0
    for m in msgs:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        roles.append(role or "?")
        if role == "user":
            c = m.get("content")
            if isinstance(c, list):
                c = "".join(p.get("text", "") for p in c if isinstance(p, dict))
            c = (c or "").strip() if isinstance(c, str) else ""
            if not (c.startswith("<tool_response>") and c.endswith("</tool_response>")):
                genuine_user += 1
    return (f"messages: n={len(roles)} genuine_user={genuine_user} "
            f"roles=[{','.join(roles)}]")

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def _relay(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        stripped = 0
        doc = None
        if body and self.path.startswith("/v1/"):
            try:
                doc = json.loads(body)
                tools = doc.get("tools")
                if isinstance(tools, list):
                    kept = [t for t in tools if not (isinstance(t, dict) and t.get("type") == "custom")]
                    stripped = len(tools) - len(kept)
                    if stripped:
                        doc["tools"] = kept
                        body = json.dumps(doc).encode()
            except Exception as e:
                log(f"shim: passthrough (unparsed body on {self.path}): {e}")
        out_headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        out_headers["Content-Length"] = str(len(body))
        req = urllib.request.Request(UPSTREAM + self.path, data=body,
                                     headers=out_headers, method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=1800)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            log(f"shim: upstream error on {self.path}: {e}")
            self.send_error(502, "shim upstream error")
            return
        if stripped:
            log(f"shim: {self.command} {self.path} stripped {stripped} custom tool(s) -> {resp.status}")
        if resp.status >= 400 and self.path.startswith("/v1/") and doc is not None:
            # Upstream rejected the request — dump the PII-safe message shape so a
            # template-side 400 (e.g. "No user query found") can be diagnosed from
            # the journal without a live repro. genuine_user=0 pinpoints the goal
            # being truncated out of the array.
            log(f"shim: {self.command} {self.path} upstream {resp.status} | {_summarize_messages(doc)}")
        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() in HOP:
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break
    do_GET = _relay
    do_POST = _relay
    do_DELETE = _relay

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    log(f"ollama-tool-shim listening on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}")
    Server((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
