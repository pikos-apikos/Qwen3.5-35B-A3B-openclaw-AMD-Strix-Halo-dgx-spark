#!/usr/bin/env bash
# install-llama-swap.sh — Download and install llama-swap binary
#
# Run as root:  sudo bash scripts/install-llama-swap.sh
set -euo pipefail

REPO="https://github.com/mostlygeek/llama-swap"
INSTALL_DIR="/opt/llama-swap"
BIN_PATH="/usr/local/bin/llama-swap"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[install-llama-swap]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install-llama-swap]${NC} $*"; }
die()     { echo -e "${RED}[install-llama-swap] ERROR:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)"

# ── Detect OS + arch ──────────────────────────────────────────────────────────
ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower]')

case "${ARCH}" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: ${ARCH}" ;;
esac

case "${OS}" in
    linux) OS="linux" ;;
    darwin) OS="darwin" ;;
    *) die "Unsupported OS: ${OS}" ;;
esac

info "Detected: ${OS}/${ARCH}"

# ── Download latest release ───────────────────────────────────────────────────
mkdir -p "${INSTALL_DIR}"

LATEST_URL="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"
DOWNLOAD_URL=$(curl -sf "${LATEST_URL}" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); \
assets=r['assets']; \
[print(a['browser_download_url']) for a in assets if '${OS}' in a['name'].lower() and '${ARCH}' in a['name'].lower()]" 2>/dev/null \
    | head -1)

if [[ -z "${DOWNLOAD_URL}" ]]; then
    # Fallback: try known asset pattern for latest tag
    TAG=$(curl -sf "${LATEST_URL}" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
    if [[ -n "${TAG}" ]]; then
        DOWNLOAD_URL="https://github.com/mostlygeek/llama-swap/releases/download/${TAG}/llama-swap-${OS}-${ARCH}"
    else
        die "Could not determine download URL. Check GitHub connectivity."
    fi
fi

info "Downloading: ${DOWNLOAD_URL}"
curl -L -o "${BIN_PATH}" "${DOWNLOAD_URL}"
chmod +x "${BIN_PATH}"

info "Installed: $(llama-swap --version 2>&1 | head -1 || echo 'ok')"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} llama-swap installed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Binary:  ${BIN_PATH}"
echo "  Config:  ${INSTALL_DIR}/config.yaml"
echo ""
echo "Next step: create ${INSTALL_DIR}/config.yaml and run scripts/setup-systemd.sh"