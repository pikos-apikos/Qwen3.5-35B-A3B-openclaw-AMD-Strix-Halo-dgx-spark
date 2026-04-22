#!/usr/bin/env bash
# setup-systemd.sh — Install llama-swap as a systemd service
#
# Run as root:  sudo bash scripts/setup-systemd.sh
# Requires:    llama-swap binary installed (run install-llama-swap.sh first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
LLAMA_SWAP_DIR="/opt/llama-swap"
CONFIG_SRC="${REPO_DIR}/llama-swap/config.yaml"
SYSTEMD_DIR="/etc/systemd/system"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup-systemd]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup-systemd]${NC} $*"; }
die()  { echo -e "${RED}[setup-systemd] ERROR:${NC} $*" >&2; exit 1; }

# ── 0. Checks ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"

# Check llama-swap binary
[[ -x /usr/local/bin/llama-swap ]] \
    || [[ -x /opt/llama-swap/llama-swap ]] \
    || die "llama-swap not found. Run install-llama-swap.sh first."

# Check config
[[ -f "${CONFIG_SRC}" ]] \
    || die "Config not found at ${CONFIG_SRC}"

# Copy config
info "Installing config to ${LLAMA_SWAP_DIR}/config.yaml..."
mkdir -p "${LLAMA_SWAP_DIR}"
cp "${CONFIG_SRC}" "${LLAMA_SWAP_DIR}/config.yaml"
chmod 644 "${LLAMA_SWAP_DIR}/config.yaml"

# Write systemd unit
info "Writing systemd unit: llama-swap.service..."
cat > "${SYSTEMD_DIR}/llama-swap.service" << EOF
[Unit]
Description=llama-swap model gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_SWAP_DIR}
ExecStart=/usr/local/bin/llama-swap --config ${LLAMA_SWAP_DIR}/config.yaml
Restart=always
RestartSec=5
StandardOutput=append:/var/log/llama-swap.log
StandardError=append:/var/log/llama-swap.log

[Install]
WantedBy=multi-user.target
EOF

# Enable + start
info "Enabling and starting llama-swap..."
systemctl daemon-reload
systemctl enable llama-swap
systemctl start llama-swap

sleep 3

# Verify
info "Verifying llama-swap health..."
if curl -sf http://127.0.0.1:8000/v1/models 2>/dev/null | python3 -c "import sys,json; json.load(sys.stdin); print('OK')" 2>/dev/null; then
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN} llama-swap is running!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Gateway:  http://127.0.0.1:8000"
    echo "  Models:   curl http://127.0.0.1:8000/v1/models"
    echo "  UI:       http://127.0.0.1:8000/ui"
    echo ""
    echo "Next step: sudo bash scripts/setup-openclaw.sh"
else
    warn "llama-swap health check failed."
    echo "Check: journalctl -u llama-swap"
fi