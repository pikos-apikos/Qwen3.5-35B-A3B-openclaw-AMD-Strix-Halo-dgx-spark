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
| `scripts/install-llama-swap.sh` | Downloads llama-swap binary |
| `scripts/setup-systemd.sh` | Installs llama-swap as a systemd service |
| `scripts/setup-openclaw.sh` | Configures openclaw to use llama-swap |
| `llama-swap/config.yaml` | Template config for llama-swap gateway |
| `openclaw/provider-snippet.json` | Drop-in config snippet for `~/.openclaw/openclaw.json` |
| `proxy/llama-proxy.py` | Optional: role/thinking rewrite proxy (see note below) |

---

## Architecture

```
openclaw  →  llama-swap (port 8000)  →  llama-server (auto-launched per model)
```

**llama-swap** ([mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)) is a lightweight model gateway that:
- Exposes a single OpenAI-compatible endpoint
- Auto-launches each model's llama-server on a free port
- Routes requests by model alias (e.g. `qwen3-coder-next`, `coder`)
- Unloads idle models after TTL (avoids VRAM thrashing)
- Supports concurrent models — one endpoint for all local LLMs

The openclaw provider uses the **`openai-responses`** API.

> **Note:** If you need role rewriting (`developer→system`, `toolResult→tool`) or thinking
> control for a raw llama-server, use `proxy/llama-proxy.py` instead of llama-swap.

---

## Why llama-swap?

The original approach used a custom Python proxy (`llama-proxy.py`) to handle two problems: unknown message roles and thinking mode. While it worked, it had limitations:

| | Custom proxy | llama-swap |
|--|--|--|
| Multi-model support | Requires manual port management | Auto-launches per model |
| Concurrent models | Not supported | Full support |
| Model TTL / unloading | Manual | Built-in TTL per model |
| OpenAI-compatible endpoint | Single model | Single endpoint, routes by alias |
| Role rewriting | ✅ Built-in | ❌ Not needed (use `openai-responses` API) |

llama-swap replaces the proxy + manual llama-server setup with a lightweight gateway that handles model lifecycle automatically. One endpoint serves all models — openclaw just picks by alias.

The original `proxy/llama-proxy.py` is kept in the repo for cases where you need role rewriting or thinking control on a standalone llama-server endpoint.

---

## Quick start

```bash
# 1. Build llama.cpp (HIP/ROCm for Strix Halo)
sudo bash scripts/install.sh

# 2. Download llama-swap binary
sudo bash scripts/install-llama-swap.sh

# 3. Install llama-swap as a systemd service
sudo bash scripts/setup-systemd.sh

# 4. Configure openclaw
sudo bash scripts/setup-openclaw.sh
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

### 2. GPU shared memory (TTM)

Strix Halo uses unified system memory — GPU-accessible memory is controlled by the kernel **Translation Table Manager (TTM)**. The default limit is too small for large models. Set it using the official `amd-ttm` tool:

```bash
# Install amd-ttm (from amd-debug-tools)
sudo apt install pipx
pipx ensurepath
pipx install amd-debug-tools

# Check current settings
amd-ttm
# Expected: TTM pages limit: ~62 GB on 128 GB systems

# Set usable shared memory (e.g. 100 GB)
sudo amd-ttm --set 100
# NOTE: You need to reboot for changes to take effect.

# Verify after reboot
amd-ttm
# Should show: TTM pages limit: 100.00 GB
```

Or manually via kernel params (legacy method):

```bash
echo "options ttm pages_limit=26214400" | sudo tee /etc/modprobe.d/ttm.conf
echo "options ttm page_pool_size=26214400" | sudo tee -a /etc/modprobe.d/ttm.conf
sudo update-initramfs -u -k all
sudo reboot
```

### 3. Model

This repo does not download a model for you. Provide your own Qwen3-Coder-Next GGUF files.

Point `setup-openclaw.sh` at your model directory by setting `MODEL_PATH` env var, or edit the script directly. Multi-part GGUF files (shards) are supported — point to the directory, not an individual file.

Default expected path: `/srv/ai/models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M`

### 3. Kernel version

Strix Halo (gfx1151) requires a minimum kernel version for full GPU compute support:

| Distro | Minimum kernel |
|--------|---------------|
| Ubuntu 24.04 HWE | `6.17.0-19.19~24.04.2` or later |
| Ubuntu 24.04 OEM | `6.14.0-1018` or later |
| Other distros | `6.18.4` or later |

Check your kernel version:

```bash
uname -r
```

For Ubuntu 24.04, install a newer HWE kernel if needed:

```bash
sudo apt install linux-image-$(uname -r | cut -d'-' -f1)-hwe-24.04-edge
sudo reboot
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

## llama-server flags (configured in llama-swap config.yaml)

llama-swap launches llama-server instances automatically. Flags per model are set in
`/opt/llama-swap/config.yaml`:

```bash
llama-server \
    --model /srv/ai/models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M \
    --ctx-size 131072 \
    --parallel 1 \
    --host 127.0.0.1 \
    --port ${PORT}          # assigned by llama-swap
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
| `--temp 0.0` | Deterministic output for coding tasks |

---

## llama-swap config

Edit `/opt/llama-swap/config.yaml` to add models or change aliases. Each model
launches on a dynamic port managed by llama-swap. See the template at
[`llama-swap/config.yaml`](llama-swap/config.yaml).

Key llama-swap endpoints:

| Endpoint | Purpose |
|----------|---------|
| `GET /v1/models` | List available models |
| `GET /running` | Show currently loaded models |
| `POST /upstream/:model_id/load` | Pre-load a model |
| `POST /upstream/:model_id/unload` | Unload a model |
| `GET /ui` | Web UI |

---

## openclaw configuration

The openclaw provider uses the **`openai-responses`** API and connects to llama-swap's
single endpoint at `http://127.0.0.1:8000/v1`.

Copy [`openclaw/provider-snippet.json`](openclaw/provider-snippet.json) into your
`~/.openclaw/openclaw.json` under `"models"` > `"providers"`:

```json
"llamacpp": {
  "baseUrl": "http://127.0.0.1:8000/v1",
  "apiKey": "llamacpp-local",
  "api": "openai-responses",
  "models": [
    {
      "id": "qwen3-coder-next",
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
"llamacpp/qwen3-coder-next": {
  "alias": "coder"
}
```

Select the model in openclaw with `/model coder` or set it as your primary
model in `agents.defaults.model.primary`.

---

## Rebuilding after upstream updates

```bash
# Rebuild llama.cpp
cd /opt/llama.cpp
git pull
cmake --build build --config Release -j $(nproc)

# Reload llama-swap (it will re-launch llama-server with the new binary)
sudo systemctl restart llama-swap
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

### llama-swap not responding

```bash
systemctl status llama-swap
journalctl -u llama-swap -n 30
curl http://127.0.0.1:8000/v1/models
```

### Model hangs on load
**Always use `-dio` flag** in the llama-swap config cmd. Without it, loading hangs silently
on models >~6 GB on Strix Halo.

### Wrong model served
Check the model `id` in your openclaw config matches the alias in `/opt/llama-swap/config.yaml`.
Aliases in llama-swap: `qwen3-coder-next`, `coder`. openclaw provider `id`: `qwen3-coder-next`.

### GPU not visible to llama-server

```bash
# Check TTM limit
cat /sys/module/ttm/parameters/pages_limit
# Should be > 20000000 for 80+ GB GPU memory

# Check kernel version is new enough
uname -r
# Must be >= 6.17 (Ubuntu 24.04 HWE) or >= 6.18.4 (other distros)

# Check /dev/kfd, /dev/dri/, render DRI permissions
ls -la /dev/kfd /dev/dri/ /dev/dri/render*
# Must be accessible to your user

# Verify ROCm sees GPU
rocminfo | grep gfx1151
# Should show: gfx1151 (Radeon 8060S)
```

### Flash attention not working
Ensure:
1. Built with `GGML_HIP_ROCWMMA_FATTN=ON`
2. Running with `-fa on` flag in llama-swap config
3. `rocwmma-dev` package is installed

### HIP VMM errors
Rebuild with `GGML_HIP_NO_VMM=ON`. This is the single most important Strix Halo flag.

### `no kernel image available`
Your build targeted the wrong GPU arch. Rebuild with `GPU_TARGETS=gfx1151`.

### Slow first response
Normal — the model needs to load into GPU memory on first request (~5s). Subsequent requests are fast.
Use the llama-swap `/upstream/:model_id/load` endpoint to pre-load before use.

---

## Acknowledgements

- [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap) — Model gateway for concurrent multi-model llama.cpp serving
- [Lychee-Technology/llama-cpp-for-strix-halo](https://github.com/Lychee-Technology/llama-cpp-for-strix-halo) — Strix Halo build documentation and prebuilt binaries
- [ggml-org/llama.cpp discussion #20856](https://github.com/ggml-org/llama.cpp/discussions/20856) — Known-good Strix Halo ROCm + llama.cpp stack
- [Jeff Geerling](https://www.jeffgeerling.com/blog/2025/increasing-vram-allocation-on-amd-ai-apus-under-linux/) — TTM memory parameter documentation
- [ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark](https://github.com/ZengboJamesWang/Qwen3.5-35B-A3B-openclaw-dgx-spark) — Original DGX Spark setup this repo is based on
