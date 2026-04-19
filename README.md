# llama.cpp + openclaw on AMD Strix Halo

Run **Qwen3-Coder-Next** locally on an AMD Strix Halo APU and use it inside **openclaw** as a fully functional AI coding agent — with tool calls and on-demand reasoning mode.

This is a fork of [ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark](https://github.com/ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark) adapted for AMD Strix Halo instead of NVIDIA DGX Spark.

## Hardware

Tested on **AMD Strix Halo** (Radeon 8060S, gfx1151, ~90 GB unified memory accessible to GPU).  
The Qwen3-Coder-Next Q4_K_M model uses ~21 GB, leaving ample headroom for context and workloads.

| Metric | Value |
|--------|-------|
| Generation speed | ~45 tok/s |
| Context window | 128k tokens |

---

## What this repo provides

| File | Purpose |
|------|---------|
| `scripts/install.sh` | Builds llama.cpp from source with HIP/ROCm (gfx1151) |
| `scripts/setup-openclaw.sh` | Installs the proxy and systemd units |
| `proxy/llama-proxy.py` | Proxy that makes llama-server compatible with openclaw |
| `systemd/llama-server.service` | systemd unit for llama-server (port 8001) |
| `systemd/llama-proxy.service` | systemd unit for the proxy (port 8000) |
| `openclaw/provider-snippet.json` | Drop-in config snippet for `~/.openclaw/openclaw.json` |

---

## Prerequisites

### 1. ROCm

`llama.cpp` on Strix Halo requires **ROCm 7.x**. Install from AMD's official repo:

```bash
# Ubuntu 24.04 example
curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/rocm.gpg

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.1 noble main" \
    | sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt-get update -qq
sudo apt-get install -y rocm-hip-sdk
```

> **Note:** Use `jammy` instead of `noble` if you are on Ubuntu 22.04.
> For the latest ROCm, replace `7.2.1` with `latest` in the repo URL.

Verify your GPU is visible:

```bash
rocminfo | grep -E "Name|gfx"
# Expected: gfx1151 (Radeon 8060S)
# Also check:  ggml_cuda_init: found 1 ROCm devices
```

Also ensure `rocwmma-dev` is installed (required for flash attention):

```bash
sudo apt-get install -y rocwmma-dev
```

### 2. Kernel TTM parameters (critical)

Strix Halo shares system RAM with the GPU, but Linux caps GPU-accessible memory by default. You **must** increase TTM limits to use >80 GB.

Add to `/etc/modprobe.d/increase_amd_memory.conf`:

```
options ttm pages_limit=25600000
options ttm page_pool_size=25600000
```

Then apply and reboot:

```bash
sudo update-initramfs -u -k all
sudo reboot
```

Verify it applied:

```bash
cat /proc/cmdline | grep ttm
# You should see: ttm.page_pool_size=25600000 ttm.pages_limit=25600000
```

### 3. Model

This repo does not download a model for you. Provide your own Qwen3-Coder-Next GGUF files.

Point `setup-openclaw.sh` at your model directory by setting `MODEL_PATH` env var, or edit the script directly. Multi-part GGUF files (shards) are supported — point to the directory, not an individual file.

Default expected path: `/srv/ai/models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M`

---

## Quick start

```bash
# 1. Build llama.cpp (HIP/ROCm for Strix Halo)
sudo bash scripts/install.sh

# 2. Install proxy + systemd services
sudo bash scripts/setup-openclaw.sh

# 3. Add the provider to openclaw (see Section 3 below)
```

Custom model path:

```bash
MODEL_PATH=/path/to/your/model sudo bash scripts/setup-openclaw.sh
```

---

## Build details

`scripts/install.sh` builds llama.cpp with the following flags for Strix Halo:

```bash
export HIPCC="$(hipconfig -l)/clang"
export HIP_PATH="$(hipconfig -R)"

cmake -S . -B build \
    -DGGML_HIP=ON \
    -DGPU_TARGETS=gfx1151 \
    -DGGML_HIP_ROCWMMA_FATTN=ON \
    -DGGML_HIP_NO_VMM=ON \
    -DGGML_HIP_MMQ_MFMA=ON \
    -DCMAKE_BUILD_TYPE=Release
```

| Flag | Purpose |
|------|---------|
| `GGML_HIP=ON` | Enable HIP/ROCm backend |
| `GPU_TARGETS=gfx1151` | Strix Halo GPU arch — **mandatory**, don't use defaults |
| `GGML_HIP_ROCWMMA_FATTN=ON` | rocWMMA flash attention — significant perf boost |
| `GGML_HIP_NO_VMM=ON` | Disable HIP VMM — **required**, VMM doesn't work on this GPU |
| `GGML_HIP_MMQ_MFMA=ON` | Improves matrix multiply path |

---

## llama-server runtime flags

The systemd unit and `setup-openclaw.sh` use these flags:

```bash
llama-server \
    --model /srv/ai/models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M \
    --ctx-size 131072 \
    --parallel 1 \
    --host 127.0.0.1 \
    --port 8001 \
    -ngl 999 \
    -fa on \
    -dio \
    --jinja
```

| Flag | Effect |
|------|--------|
| `-ngl 999` | Offload all layers to GPU (use 999, not 99) |
| `-fa on` | Flash attention (requires `GGML_HIP_ROCWMMA_FATTN=ON` at build time) |
| `-dio` | **Required for models >~6 GB** — without this, loading hangs |
| `--jinja` | Enable Jinja chat template processing |
| `--parallel 1` | Best single-user throughput |
| `--ctx-size 131072` | 128k context |

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
cp proxy/llama-proxy.py /opt/llama.cpp/llama-proxy.py
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
[think] explain the difference between a mutex and a semaphore
```

The keyword is stripped before the message reaches the model.

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
      "id": "Qwen3-Coder-Next-Q4_K_M",
      "name": "Qwen3-Coder-Next (local, Strix Halo)",
      "reasoning": false,
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
"llamacpp/Qwen3-Coder-Next-Q4_K_M": {
  "alias": "coder"
}
```

You can now select the model in openclaw with `/model coder` or set it as your primary
model in the `agents.defaults.model.primary` field.

---

## Rebuilding after upstream updates

```bash
cd /opt/llama.cpp
git pull
cmake --build build --config Release -j $(nproc)
sudo systemctl restart llama-server
```

---

## GPU memory reference (AMD Strix Halo)

| Model | Quant | GPU-accessible memory |
|-------|-------|----------------------|
| Qwen3-Coder-Next | Q4_K_M | ~21 GB |
| Qwen3.5-35B-A3B | UD-Q4_K_XL | ~20 GB |
| 70B dense | Q4_K_M | ~40 GB |
| 120B dense | Q4_K_M | ~70 GB |

Strix Halo has ~90 GB GPU-accessible unified memory (up to 128 GB depending on config). KV cache adds ~0.5 GB per 32k context with flash attention.

---

## Troubleshooting

### `HTTP 500: Unexpected message role`
The proxy is not running or openclaw is not pointing at port 8000.

```bash
systemctl status llama-proxy
curl http://127.0.0.1:8000/health
```

### Model hangs on load
**Always use `-dio` flag.** Without it, loading hangs silently on models >~6 GB on Strix Halo.

### GPU not visible to llama-server
Check `/dev/kfd`, `/dev/dri/card0`, `/dev/dri/renderD128` are accessible.
If running in a container/LXC, ensure device passthrough is correct.

```bash
rocminfo | grep gfx1151
# Should show: gfx1151
```

### Flash attention not working
Ensure:
1. Built with `GGML_HIP_ROCWMMA_FATTN=ON`
2. Running with `-fa on` flag
3. `rocwmma-dev` package is installed

### HIP VMM errors
Rebuild with `GGML_HIP_NO_VMM=ON`. This is the single most important Strix Halo flag.

### `no kernel image available`
Your build targeted the wrong GPU arch. Rebuild with `GPU_TARGETS=gfx1151`.

### Slow first response
Normal — the model needs to load into GPU memory on first request (~5s). Subsequent requests are fast.

---

## Acknowledgements

- [Lychee-Technology/llama-cpp-for-strix-halo](https://github.com/Lychee-Technology/llama-cpp-for-strix-halo) — Strix Halo build documentation and prebuilt binaries
- [ggml-org/llama.cpp discussion #20856](https://github.com/ggml-org/llama.cpp/discussions/20856) — Known-good Strix Halo ROCm + llama.cpp stack
- [Jeff Geerling](https://www.jeffgeerling.com/blog/2025/increasing-vram-allocation-on-amd-ai-apus-under-linux/) — TTM memory parameter documentation
- [ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark](https://github.com/ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark) — Original DGX Spark setup this repo is based on
