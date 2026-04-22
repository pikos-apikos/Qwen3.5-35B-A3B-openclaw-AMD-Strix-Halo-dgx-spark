#!/usr/bin/env bash
# setup-openclaw.sh — Configure openclaw to use llama-swap
#
# Run as root:  sudo bash scripts/setup-openclaw.sh
# Requires:    llama-swap running (run setup-systemd.sh first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
SNIPPET="${REPO_DIR}/openclaw/provider-snippet.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup-openclaw]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup-openclaw]${NC} $*"; }
die()  { echo -e "${RED}[setup-openclaw] ERROR:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"

# Verify llama-swap is running
if ! systemctl is-enabled llama-swap &>/dev/null; then
    die "llama-swap is not installed. Run setup-systemd.sh first."
fi

if ! systemctl is-active llama-swap &>/dev/null; then
    warn "llama-swap is not running — starting it..."
    systemctl start llama-swap
fi

if ! curl -sf http://127.0.0.1:8000/v1/models 2>/dev/null | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    die "llama-swap not responding at http://127.0.0.1:8000 — check journalctl -u llama-swap"
fi

info "llama-swap is up at http://127.0.0.1:8000"

# List available models
echo ""
echo "Available models:"
curl -sf http://127.0.0.1:8000/v1/models 2>/dev/null \
    | python3 -c "import sys,json; [print(f'  - {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
    || echo "  (could not enumerate models)"

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
echo "Or copy the full snippet:"
echo "  cp ${SNIPPET} ~/.openclaw/"
echo ""
echo "And merge it into your existing ~/.openclaw/openclaw.json."
echo ""
echo "The api is set to 'openai-responses' which openclaw uses for"
echo "the Responses API (stateless, streaming-compatible)."
echo ""
echo "Model aliases in llama-swap config are: qwen3-coder-next, coder"
echo ""
echo "Restart openclaw after editing ~/.openclaw/openclaw.json"
echo ""
echo "Verify:"
echo "  curl http://127.0.0.1:8000/v1/models"