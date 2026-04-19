#!/usr/bin/env bash
# setup-systemd.sh — Install llama-server + llama-proxy as systemd services
#
# Run as root:  sudo bash scripts/setup-systemd.sh
# Requires:    llama.cpp already installed (run install.sh first)
#
# This script does NOT install openclaw. Use setup-openclaw.sh for that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
INSTALL_DIR="/opt/llama.cpp"
PROXY_SRC="${REPO_DIR}/proxy/llama-proxy.py"
SYSTEMD_DIR="/etc/systemd/system"

# ── Model path (edit if your model is elsewhere) ───────────────────────────────
# Multi-part GGUF: point to any shard — llama-server discovers the rest automatically
MODEL_PATH="${MODEL_PATH:-/srv/ai/models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M}"

# Detect the user who invoked sudo (so we run services as that user, not root)
SERVICE_USER="${SUDO_USER:-$(logname 2>/dev/null || echo nobody)}"
PYTHON_BIN="$(su - "${SERVICE_USER}" -c 'which python3' 2>/dev/null || which python3)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup-systemd]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup-systemd]${NC} $*"; }
die()  { echo -e "${RED}[setup-systemd] ERROR:${NC} $*" >&2; exit 1; }

# ── 0. Checks ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"
[[ -f "${PROXY_SRC}" ]] || die "Proxy script not found at ${PROXY_SRC}"
command -v llama-server &>/dev/null \
    || [[ -x /usr/local/bin/llama-server ]] \
    || [[ -x /opt/llama.cpp/build/bin/llama-server ]] \
    || die "llama-server not found — run install.sh first"

# ── 1. Copy proxy script ──────────────────────────────────────────────────────
info "Installing proxy to ${INSTALL_DIR}/llama-proxy.py..."
cp "${PROXY_SRC}" "${INSTALL_DIR}/llama-proxy.py"
chmod 755 "${INSTALL_DIR}/llama-proxy.py"

# ── 2. Write systemd units ────────────────────────────────────────────────────
info "Writing systemd unit: llama-server.service (port 8001)..."
cat > "${SYSTEMD_DIR}/llama-server.service" << EOF
[Unit]
Description=llama.cpp server (Strix Halo)
After=network.target
Before=llama-proxy.service

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=/usr/local/bin/llama-server \\
    --model ${MODEL_PATH} \\
    --ctx-size 131072 \\
    --parallel 1 \\
    --host 127.0.0.1 \\
    --port 8001 \\
    -ngl 999 \\
    -fa on \\
    -dio \\
    --jinja
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/llama-server.log
StandardError=append:/var/log/llama-server.log
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

info "Writing systemd unit: llama-proxy.service (port 8000)..."
cat > "${SYSTEMD_DIR}/llama-proxy.service" << EOF
[Unit]
Description=llama-proxy (role rewrite + thinking control, port 8000->8001)
After=network.target llama-server.service
Requires=llama-server.service

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${PYTHON_BIN} ${INSTALL_DIR}/llama-proxy.py
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/llama-proxy.log
StandardError=append:/var/log/llama-proxy.log

[Install]
WantedBy=multi-user.target
EOF

# ── 3. Enable + start ─────────────────────────────────────────────────────────
info "Enabling and starting services..."
systemctl daemon-reload
systemctl enable llama-server llama-proxy

systemctl start llama-server
info "Waiting for llama-server to load model (up to 120s)..."
timeout 120 bash -c \
    'until curl -sf http://127.0.0.1:8001/health 2>/dev/null | grep -q ok; do sleep 3; printf "."; done' \
    && echo ""

systemctl start llama-proxy
sleep 2

# ── 4. Verify ─────────────────────────────────────────────────────────────────
info "Verifying llama-server health..."
if curl -sf http://127.0.0.1:8001/health 2>/dev/null | grep -q ok; then
    info "llama-server: OK"
else
    warn "llama-server health check failed. Check: journalctl -u llama-server"
fi

info "Verifying llama-proxy health..."
PROXY_HEALTH=$(curl -sf http://127.0.0.1:8000/health 2>/dev/null || echo "FAILED")
if echo "${PROXY_HEALTH}" | grep -q ok; then
    info "llama-proxy: OK"
else
    warn "llama-proxy health check failed. Check: journalctl -u llama-proxy"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} systemd services installed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  llama-server  →  http://127.0.0.1:8001"
echo "  llama-proxy   →  http://127.0.0.1:8000"
echo ""
echo "To manage services:"
echo "  systemctl status llama-server llama-proxy"
echo "  journalctl -u llama-server -u llama-proxy -f"
echo "  systemctl restart llama-server  # after rebuilding llama.cpp"
echo ""
if [[ -d "${REPO_DIR}/openclaw" ]]; then
    echo "Next step: sudo bash scripts/setup-openclaw.sh  # configure openclaw"
fi