# llama.cpp + openclaw on NVIDIA DGX Spark (GB10)

Run **Qwen3.5-35B-A3B** locally on the DGX Spark and use it inside **openclaw** as a fully functional AI agent — including tool calls and on-demand reasoning mode.

## Hardware

Tested on **NVIDIA DGX Spark** (GB10 Superchip, sm_121, ~122 GB unified memory).  
The Qwen3.5-35B-A3B MoE model uses ~20 GB, leaving ~100 GB free for context and other workloads.

| Metric | Value |
|--------|-------|
| Generation speed | ~43 tok/s |
| Prefill speed | ~63 tok/s |
| Context window | 128k tokens |

---

## What this repo provides

| File | Purpose |
|------|---------|
| `scripts/install.sh` | Builds llama.cpp from source with CUDA (sm_121) and downloads the model |
| `scripts/setup-openclaw.sh` | Installs the proxy and systemd units |
| `proxy/llama-proxy.py` | Proxy that makes llama-server compatible with openclaw |
| `systemd/llama-server.service` | systemd unit for llama-server (port 8001) |
| `systemd/llama-proxy.service` | systemd unit for the proxy (port 8000) |
| `openclaw/provider-snippet.json` | Drop-in config snippet for `~/.openclaw/openclaw.json` |

---

## Quick start

```bash
# 1. Build llama.cpp and download model
sudo bash scripts/install.sh

# 2. Install proxy + systemd services
sudo bash scripts/setup-openclaw.sh

# 3. Add the provider to openclaw (see Section 3 below)
```

---

## Section 1 — Install llama.cpp and the Qwen model

See [`scripts/install.sh`](scripts/install.sh) for the full automated script, or follow the steps below manually.

### Prerequisites

```bash
sudo apt-get install -y git cmake build-essential patchelf
# CUDA toolkit must already be installed (comes with DGX Spark OS image)
```

### Build llama.cpp

```bash
git clone https://github.com/ggerganov/llama.cpp /opt/llama.cpp
cd /opt/llama.cpp

cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build --config Release -j $(nproc)

# Make binary available system-wide
ln -sf /opt/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

# Register shared libs
echo "/opt/llama.cpp/build/bin" > /etc/ld.so.conf.d/llama.conf
ldconfig
```

> **Note on CUDA arch:** GB10 is `sm_121`. The build uses `120` (the closest supported
> target in current llama.cpp). Do not use `native` — cmake may fail to detect sm_121.

### Download the model

```bash
mkdir -p /opt/llama.cpp/models
pip install huggingface_hub

huggingface-cli download \
  unsloth/Qwen3.5-35B-A3B-GGUF \
  --include "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf" \
  --local-dir /opt/llama.cpp/models/
```

**Why this model?**
- `UD` = Unsloth Dynamic quantisation — smarter bit allocation than standard Q4_K_XL
- Only ~20 GB vs ~37 GB for the original full-size quant
- ~43 tok/s on GB10 vs ~21 tok/s for the larger quant

### Start llama-server

```bash
llama-server \
  --model /opt/llama.cpp/models/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --ctx-size 131072 \
  --parallel 1 \
  --host 127.0.0.1 \
  --port 8001 \
  -ngl 99 \
  -fa on
```

Key flags:

| Flag | Effect |
|------|--------|
| `-ngl 99` | Offload all layers to GPU |
| `-fa on` | Flash attention — significant speed boost |
| `--parallel 1` | Best single-user throughput |
| `--ctx-size 131072` | 128k context |
| `--host 127.0.0.1` | Loopback only — the proxy is the public interface |

Verify it started:

```bash
curl http://127.0.0.1:8001/health
# {"status":"ok"}
```

---

## Section 2 — Making it work with openclaw (the proxy)

openclaw cannot talk to llama-server directly. Two incompatibilities need to be fixed:

### Problem 1: Unknown message roles

openclaw sends messages with roles that the Qwen3.5 Jinja chat template does not accept:

| openclaw sends | Qwen3.5 expects | Fix |
|----------------|-----------------|-----|
| `"role": "developer"` | `"role": "system"` | Rewrite in proxy |
| `"role": "toolResult"` | `"role": "tool"` | Rewrite in proxy |

Without this fix, every request returns `HTTP 500: Unexpected message role.`

### Problem 2: Thinking mode

Qwen3.5 is a reasoning model. By default it spends tokens on a `<think>` block before
answering. openclaw has no way to control this — the model would consume all its token
budget thinking and return an empty `content` field.

### The proxy

`proxy/llama-proxy.py` is a lightweight Python proxy (stdlib only, no dependencies)
that sits between openclaw and llama-server:

```
openclaw  →  port 8000 (llama-proxy)  →  port 8001 (llama-server)
```

It does three things on every request:

1. Rewrites `developer` → `system` and `toolResult` → `tool`
2. Injects `{"enable_thinking": false}` by default (fast direct answers)
3. If the user's message starts with `[think]`, strips the keyword and injects
   `{"enable_thinking": true}` instead (full reasoning mode)

### Install the proxy as a systemd service

```bash
sudo bash scripts/setup-openclaw.sh
```

Or manually:

```bash
# Copy proxy script
cp proxy/llama-proxy.py /opt/llama.cpp/llama-proxy.py

# Install systemd units
cp systemd/llama-server.service /etc/systemd/system/
cp systemd/llama-proxy.service  /etc/systemd/system/

systemctl daemon-reload
systemctl enable llama-server llama-proxy
systemctl start  llama-server llama-proxy
```

Verify:

```bash
curl http://127.0.0.1:8000/health
# {"status":"ok"}
```

### Using `[think]` mode

Prefix any message in openclaw with `[think]` to enable reasoning:

```
[think] why is my recursive fibonacci O(2^n) and how do I fix it?
```

The keyword is stripped before the model sees it. The response will include the model's
full reasoning chain alongside the answer.  
Use it for: hard debugging, complex architecture decisions, math, logic.

---

## Section 3 — Configure openclaw

Add the `llamacpp` provider to `~/.openclaw/openclaw.json`.

The full snippet is in [`openclaw/provider-snippet.json`](openclaw/provider-snippet.json).

In your `openclaw.json`, merge the following into `"models" > "providers"`:

```json
"llamacpp": {
  "baseUrl": "http://127.0.0.1:8000/v1",
  "apiKey": "llamacpp-local",
  "api": "openai-completions",
  "models": [
    {
      "id": "Qwen3.5-35B-A3B",
      "name": "Qwen3.5-35B-A3B (local)",
      "reasoning": true,
      "input": ["text"],
      "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
      "contextWindow": 131072,
      "maxTokens": 32768
    }
  ]
}
```

And in `"agents" > "defaults" > "models"`, add an alias:

```json
"llamacpp/Qwen3.5-35B-A3B": {
  "alias": "qwen"
}
```

You can now select the model in openclaw with `/model qwen` or set it as your primary
model in the `agents.defaults.model.primary` field.

### Verify tool calls work

Send a message that triggers a tool (e.g. a web search). If the proxy is running and
the roles are being rewritten, the tool call will complete without errors.

---

## Rebuilding after upstream updates

```bash
cd /opt/llama.cpp
git pull
cmake --build build --config Release -j $(nproc)
sudo systemctl restart llama-server
```

---

## GPU memory reference (NVIDIA GB10)

| Model | Quant | VRAM |
|-------|-------|------|
| Qwen3.5-35B-A3B | UD-Q4_K_XL | ~20 GB |
| Qwen3.5-35B-A3B | Q4_K_XL (original) | ~37 GB |
| 70B dense | Q4_K_M | ~40 GB |
| 120B dense | Q4_K_M | ~70 GB |

Total unified memory: ~122 GB. KV cache adds on top of model size (~0.5 GB per 32k context with flash attention).

---

## Troubleshooting

### `HTTP 500: Unexpected message role`
The proxy is not running or openclaw is not pointing at port 8000.
```bash
systemctl status llama-proxy
curl http://127.0.0.1:8000/health
```

### No response / empty content
The model is in thinking mode and exhausted its token budget before answering.
Make sure the proxy is running — it injects `enable_thinking: false` by default.

### Slow first response
Normal — the model needs to load into GPU memory on first request (~5s). Subsequent requests are fast.

### `CUDA error: no kernel image is available for execution`
Your llama.cpp build targeted the wrong CUDA arch. Rebuild with `-DCMAKE_CUDA_ARCHITECTURES=120`.
