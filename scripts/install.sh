#!/usr/bin/env bash
# install.sh — Build llama.cpp from source (CUDA, sm_121) and download Qwen model
#
# Run as root:  sudo bash scripts/install.sh
# Tested on:   NVIDIA DGX Spark (GB10, sm_121), Ubuntu 22.04/24.04
set -euo pipefail

INSTALL_DIR="/opt/llama.cpp"
MODEL_DIR="${INSTALL_DIR}/models"
MODEL_REPO="unsloth/Qwen3.5-35B-A3B-GGUF"
MODEL_FILE="Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf"
LLAMA_REPO="https://github.com/ggerganov/llama.cpp"
CUDA_ARCH="120"   # sm_121 (GB10) — use 120, the nearest supported arch

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[install]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install]${NC} $*"; }
die()     { echo -e "${RED}[install] ERROR:${NC} $*" >&2; exit 1; }

# ── 0. Root check ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"

# ── 1. Dependencies ───────────────────────────────────────────────────────────
info "Installing build dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    git cmake build-essential patchelf python3-pip curl

# ── 2. Clone or update llama.cpp ──────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "llama.cpp already cloned at ${INSTALL_DIR}, pulling latest..."
    git -C "${INSTALL_DIR}" pull --ff-only
else
    info "Cloning llama.cpp into ${INSTALL_DIR}..."
    git clone "${LLAMA_REPO}" "${INSTALL_DIR}"
fi

# ── 3. Build ──────────────────────────────────────────────────────────────────
info "Configuring CMake (CUDA arch ${CUDA_ARCH})..."
cmake -S "${INSTALL_DIR}" -B "${INSTALL_DIR}/build" \
    -DGGML_CUDA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"

info "Building (this takes a few minutes)..."
cmake --build "${INSTALL_DIR}/build" --config Release -j "$(nproc)"

# ── 4. Install binary + shared libs ───────────────────────────────────────────
info "Installing llama-server to /usr/local/bin..."
ln -sf "${INSTALL_DIR}/build/bin/llama-server" /usr/local/bin/llama-server

# Patch RUNPATH so the binary finds its shared libs
if command -v patchelf &>/dev/null; then
    patchelf --set-rpath "${INSTALL_DIR}/build/bin" \
        "${INSTALL_DIR}/build/bin/llama-server" 2>/dev/null || true
fi

echo "${INSTALL_DIR}/build/bin" > /etc/ld.so.conf.d/llama.conf
ldconfig
info "Binary installed: $(llama-server --version 2>&1 | grep version || echo 'ok')"

# ── 5. Download model ─────────────────────────────────────────────────────────
mkdir -p "${MODEL_DIR}"

if [[ -f "${MODEL_DIR}/${MODEL_FILE}" ]]; then
    info "Model already present at ${MODEL_DIR}/${MODEL_FILE}, skipping download."
else
    info "Downloading ${MODEL_FILE} from Hugging Face (~20 GB)..."
    # Try huggingface-cli first, fall back to wget
    if python3 -c "import huggingface_hub" 2>/dev/null; then
        python3 -m huggingface_hub.cli.cli download \
            "${MODEL_REPO}" \
            --include "${MODEL_FILE}" \
            --local-dir "${MODEL_DIR}/" || \
        huggingface-cli download \
            "${MODEL_REPO}" \
            --include "${MODEL_FILE}" \
            --local-dir "${MODEL_DIR}/"
    else
        pip3 install -q huggingface_hub
        huggingface-cli download \
            "${MODEL_REPO}" \
            --include "${MODEL_FILE}" \
            --local-dir "${MODEL_DIR}/"
    fi
    info "Model downloaded: ${MODEL_DIR}/${MODEL_FILE}"
fi

# ── 6. Smoke test ─────────────────────────────────────────────────────────────
info "Running quick smoke test (llama-server --version)..."
llama-server --version 2>&1 | head -3

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} llama.cpp installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Model:   ${MODEL_DIR}/${MODEL_FILE}"
echo "  Binary:  $(which llama-server)"
echo ""
echo "Next step:  sudo bash scripts/setup-openclaw.sh"
echo ""
