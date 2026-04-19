#!/usr/bin/env bash
# setup-openclaw.sh — Configure openclaw to use the existing llama-proxy
#
# Run as root:  sudo bash scripts/setup-openclaw.sh
# Requires:    systemd services already installed (run setup-systemd.sh first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup-openclaw]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup-openclaw]${NC} $*"; }
die()  { echo -e "${RED}[setup-openclaw] ERROR:${NC} $*" >&2; exit 1; }

# ── 0. Checks ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"

# Verify services are running
for svc in llama-server llama-proxy; do
    if ! systemctl is-enabled "$svc" &>/dev/null; then
        die "$svc is not installed. Run setup-systemd.sh first."
    fi
    if ! systemctl is-active "$svc" &>/dev/null; then
        warn "$svc is not running — starting it..."
        systemctl start "$svc"
    fi
done

# Verify the proxy is reachable
if ! curl -sf http://127.0.0.1:8000/health 2>/dev/null | grep -q ok; then
    die "llama-proxy not responding at http://127.0.0.1:8000 — check journalctl -u llama-proxy"
fi

# ── 1. Show openclaw config snippet ───────────────────────────────────────────
SNIPPET="${REPO_DIR}/openclaw/provider-snippet.json"
if [[ ! -f "${SNIPPET}" ]]; then
    die "openclaw/provider-snippet.json not found"
fi

info "llama-proxy is up at http://127.0.0.1:8000"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} openclaw configuration${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Add the following to your ~/.openclaw/openclaw.json"
echo "under \"models\" > \"providers\":"
echo ""

cat "${SNIPPET}"

echo ""
echo "Alternatively, copy the full snippet:"
echo "  cp ${SNIPPET} ~/.openclaw/"
echo ""
echo "And merge it into your existing ~/.openclaw/openclaw.json"
echo ""
echo "Example openclaw.json entry for agents.defaults.models:"
echo '  "llamacpp/Qwen3-Coder-Next-Q4_K_M": { "alias": "coder" }'
echo ""
echo "After editing ~/.openclaw/openclaw.json, restart openclaw."
echo ""
echo "Verify the proxy is working:"
echo "  curl http://127.0.0.1:8000/health"
echo "  # Expected: {\"status\":\"ok\"}"