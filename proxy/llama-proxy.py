#!/usr/bin/env python3
"""
llama-proxy.py — Lightweight HTTP proxy that makes llama-server compatible with openclaw.

Problems solved:
  1. openclaw sends "role": "developer" (OpenAI o1/o3 convention) and "role": "toolResult"
     (openclaw internal) — the Qwen3.5 Jinja chat template only accepts system/user/assistant/tool,
     so it throws HTTP 500 on any other role. This proxy rewrites them before forwarding.

  2. Qwen3.5 is a reasoning model. By default it spends all its tokens on a <think> block
     and returns empty content. This proxy disables thinking by default and re-enables it
     on demand via a [think] keyword prefix in the user's message.

Ports:
  Listens on  : 8000  (openclaw connects here)
  Forwards to : 8001  (llama-server)

Usage:
  python3 llama-proxy.py

[think] keyword:
  Prefix any message with [think] to enable the model's full reasoning mode:
    [think] explain why quicksort is O(n log n) on average
  The keyword is stripped before the message reaches the model.
"""

import http.server
import urllib.request
import urllib.error
import json
import sys
import logging

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8000
BACKEND_URL = "http://127.0.0.1:8001"
CHUNK_SIZE = 64 * 1024  # 64 KB streaming chunks
THINK_KEYWORD = "[think]"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [proxy] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("llama-proxy")


# ── Message rewriting ─────────────────────────────────────────────────────────

def rewrite_messages(messages):
    """Fix messages list for Qwen3.5 template compatibility.

    Rules:
    1. developer  → system   (OpenAI o1/o3 convention)
    2. toolResult → tool     (openclaw internal convention)
    3. system messages after position 0 are merged into the first system message
       (Qwen3.5 template raises if a system message is not first)
    """
    if not isinstance(messages, list):
        return messages

    # Step 1: rewrite individual roles
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if role == "developer":
            msg["role"] = "system"
            log.info("Rewrote role: developer → system")
        elif role == "toolResult":
            msg["role"] = "tool"
            log.info("Rewrote role: toolResult → tool")

    # Step 2: collapse mid-conversation system messages into the first one
    first_system_idx = next(
        (i for i, m in enumerate(messages) if isinstance(m, dict) and m.get("role") == "system"),
        None,
    )
    out = []
    for i, msg in enumerate(messages):
        if not isinstance(msg, dict):
            out.append(msg)
            continue
        if msg.get("role") == "system" and i != first_system_idx and first_system_idx is not None:
            first_content = messages[first_system_idx].get("content") or ""
            extra = msg.get("content") or ""
            messages[first_system_idx]["content"] = (first_content + "\n\n" + extra).strip()
            log.info("Merged mid-conversation system message into first system message")
            continue
        out.append(msg)
    return out


def check_and_strip_think_keyword(messages):
    """Return True and strip [think] if the last user message starts with it."""
    if not isinstance(messages, list):
        return False
    for msg in reversed(messages):
        if isinstance(msg, dict) and msg.get("role") == "user":
            content = msg.get("content") or ""
            if isinstance(content, str) and content.lstrip().lower().startswith(THINK_KEYWORD):
                msg["content"] = content.lstrip()[len(THINK_KEYWORD):].lstrip()
                log.info("Detected [think] keyword — enabling thinking mode")
                return True
            break
    return False


def rewrite_body(obj):
    """Apply all rewrites to the parsed request body."""
    if not (isinstance(obj, dict) and "messages" in obj):
        return obj

    thinking = check_and_strip_think_keyword(obj["messages"])
    obj["messages"] = rewrite_messages(obj["messages"])

    # Control thinking per-request via chat_template_kwargs.
    # Default: off (fast direct answers). [think] prefix: on (full reasoning).
    kwargs = obj.setdefault("chat_template_kwargs", {})
    if thinking:
        kwargs["enable_thinking"] = True
    elif "enable_thinking" not in kwargs:
        kwargs["enable_thinking"] = False

    return obj


# ── Proxy handler ─────────────────────────────────────────────────────────────

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        log.info(format % args)

    def do_request(self, method):
        # Read body — handle both Content-Length and chunked transfer encoding
        content_length_hdr = self.headers.get("Content-Length")
        transfer_encoding = self.headers.get("Transfer-Encoding", "").lower()

        if content_length_hdr is not None:
            body = self.rfile.read(int(content_length_hdr))
        elif "chunked" in transfer_encoding:
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                if not size_line:
                    break
                try:
                    chunk_size = int(size_line, 16)
                except ValueError:
                    break
                if chunk_size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                chunk = self.rfile.read(chunk_size)
                self.rfile.read(2)  # CRLF after chunk
                chunks.append(chunk)
            body = b"".join(chunks)
        else:
            body = b""

        # Rewrite JSON body
        content_type = self.headers.get("Content-Type", "")
        if body and "application/json" in content_type:
            try:
                parsed = json.loads(body)
                if "messages" in parsed:
                    roles = [m.get("role") for m in parsed["messages"]]
                    log.info("Roles in request: %s", roles)
                body = json.dumps(rewrite_body(parsed)).encode("utf-8")
            except Exception as e:
                log.warning("Could not parse/rewrite JSON body: %s", e)

        # Forward to backend
        target_url = BACKEND_URL + self.path
        req = urllib.request.Request(
            target_url,
            data=body if body else None,
            method=method,
        )
        skip_headers = {"host", "content-length", "transfer-encoding", "connection"}
        for key, value in self.headers.items():
            if key.lower() not in skip_headers:
                req.add_header(key, value)
        if body:
            req.add_header("Content-Length", str(len(body)))

        # Stream response back
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() not in {"transfer-encoding", "connection"}:
                        self.send_header(key, value)
                self.end_headers()
                while True:
                    chunk = resp.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()

        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for key, value in e.headers.items():
                if key.lower() not in {"transfer-encoding", "connection"}:
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(e.read())

        except Exception as e:
            log.error("Proxy error: %s", e)
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Proxy error: {e}".encode())

    def do_GET(self):     self.do_request("GET")
    def do_POST(self):    self.do_request("POST")
    def do_PUT(self):     self.do_request("PUT")
    def do_DELETE(self):  self.do_request("DELETE")
    def do_OPTIONS(self): self.do_request("OPTIONS")
    def do_HEAD(self):    self.do_request("HEAD")


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    log.info("llama-proxy listening on %s:%d → %s", LISTEN_HOST, LISTEN_PORT, BACKEND_URL)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
        server.shutdown()
