#!/usr/bin/env bash
# install.sh — Build llama.cpp from source (HIP/ROCm for AMD Strix Halo)
#
# Run as root:  sudo bash scripts/install.sh
# Tested on:   AMD Strix Halo (gfx1151), Ubuntu 22.04/24.04, ROCm 7.x
set -euo pipefail

INSTALL_DIR="/opt/llama.cpp"
MODEL_DIR="${INSTALL_DIR}/models"
# NOTE: Model download skipped — user provides their own model
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"

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

# Verify ROCm is installed
if ! command -v hipconfig &>/dev/null; then
    die "ROCm/hipconfig not found. Install ROCm first: https://rocm.docs.amd.com/"
fi

# ── 2. Clone or update llama.cpp ──────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "llama.cpp already cloned at ${INSTALL_DIR}, pulling latest..."
    git -C "${INSTALL_DIR}" pull --ff-only
else
    info "Cloning llama.cpp into ${INSTALL_DIR}..."
    git clone "${LLAMA_REPO}" "${INSTALL_DIR}"
fi

# ── 3. Build for AMD Strix Halo (HIP/ROCm) ───────────────────────────────────
info "Configuring CMake for AMD Strix Halo (gfx1151, HIP/ROCm)..."
export HIPCC="$(hipconfig -l)/clang"
export HIP_PATH="$(hipconfig -R)"

cmake -S "${INSTALL_DIR}" -B "${INSTALL_DIR}/build" \
    -DGGML_HIP=ON \
    -DGPU_TARGETS=gfx1151 \
    -DGGML_HIP_ROCWMMA_FATTN=ON \
    -DGGML_HIP_NO_VMM=ON \
    -DGGML_HIP_MMQ_MFMA=ON \
    -DCMAKE_BUILD_TYPE=Release

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

# ── 5. Model ─────────────────────────────────────────────────────────────────
# Model installation is skipped — mount or link your existing model directory to:
#   ${MODEL_DIR}/
# The setup-openclaw.sh script will reference your model path.

info "Model directory: ${MODEL_DIR}/"
info "Link or copy your GGUF model files there before starting services."

# ── 6. Smoke test ─────────────────────────────────────────────────────────────
info "Running quick smoke test (llama-server --version)..."
llama-server --version 2>&1 | head -3

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} llama.cpp installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Binary:  $(which llama-server)"
echo "  Model dir: ${MODEL_DIR}/"
echo ""
echo "Next step:  sudo bash scripts/setup-openclaw.sh"
echo ""
