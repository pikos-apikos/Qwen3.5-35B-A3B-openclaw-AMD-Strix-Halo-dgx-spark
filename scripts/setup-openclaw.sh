#!/usr/bin/env bash
# setup-openclaw.sh — Install llama-proxy + systemd services
#
# Run as root:  sudo bash scripts/setup-openclaw.sh
# Requires:    llama.cpp already installed (run install.sh first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
INSTALL_DIR="/opt/llama.cpp"
PROXY_SRC="${REPO_DIR}/proxy/llama-proxy.py"
SYSTEMD_DIR="/etc/systemd/system"

# Detect the user who invoked sudo (so we run the proxy as that user, not root)
PROXY_USER="${SUDO_USER:-$(logname 2>/dev/null || echo nobody)}"
PYTHON_BIN="$(su - "${PROXY_USER}" -c 'which python3' 2>/dev/null || which python3)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
die()  { echo -e "${RED}[setup] ERROR:${NC} $*" >&2; exit 1; }

# ── 0. Checks ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"
[[ -f "${PROXY_SRC}" ]] || die "Proxy script not found at ${PROXY_SRC}"
command -v llama-server &>/dev/null || die "llama-server not found — run install.sh first"

# ── 1. Copy proxy script ──────────────────────────────────────────────────────
info "Installing proxy to ${INSTALL_DIR}/llama-proxy.py..."
cp "${PROXY_SRC}" "${INSTALL_DIR}/llama-proxy.py"
chmod 755 "${INSTALL_DIR}/llama-proxy.py"

# ── 2. Write systemd units (with detected user + python path) ─────────────────
info "Writing systemd unit: llama-server.service (port 8001)..."
cat > "${SYSTEMD_DIR}/llama-server.service" << EOF
[Unit]
Description=llama.cpp server (Qwen3.5-35B-A3B)
After=network.target
Before=llama-proxy.service

[Service]
Type=simple
User=${PROXY_USER}
ExecStart=/usr/local/bin/llama-server \\
    --model ${INSTALL_DIR}/models/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \\
    --ctx-size 131072 \\
    --parallel 1 \\
    --host 127.0.0.1 \\
    --port 8001 \\
    -ngl 99 \\
    -fa on
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
User=${PROXY_USER}
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

# Start llama-server and wait for it to be ready
systemctl start llama-server
info "Waiting for llama-server to load model (up to 120s)..."
timeout 120 bash -c \
    'until curl -sf http://127.0.0.1:8001/health 2>/dev/null | grep -q ok; do sleep 3; printf "."; done' \
    && echo ""

systemctl start llama-proxy
sleep 2

# ── 4. Verify ─────────────────────────────────────────────────────────────────
info "Verifying proxy health check..."
HEALTH=$(curl -sf http://127.0.0.1:8000/health 2>/dev/null || echo "FAILED")
if echo "${HEALTH}" | grep -q ok; then
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN} Setup complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  llama-server  →  http://127.0.0.1:8001  (internal)"
    echo "  llama-proxy   →  http://127.0.0.1:8000  (openclaw connects here)"
    echo ""
    echo "Next step: add the llamacpp provider to ~/.openclaw/openclaw.json"
    echo "  See: openclaw/provider-snippet.json"
    echo ""
else
    die "Proxy health check failed. Check: journalctl -u llama-proxy -u llama-server"
fi
