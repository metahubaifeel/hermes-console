#!/usr/bin/env bash
# Pre-install checks. Exit 0 = ready; non-zero = missing requirement.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../hermes_detect.sh
source "$ROOT/hermes_detect.sh"

fail=0
has_warn=0

ok()   { echo "[ok]   $*"; }
note_warn() { echo "[warn] $*"; has_warn=1; }
bad()  { echo "[fail] $*"; fail=1; }

echo "Hermes Console preflight"
echo "  HERMES_HOME=$HERMES_HOME"
echo ""

if [[ "$(uname -s)" != "Linux" ]]; then
  bad "Linux required (systemd user session)"
else
  ok "Linux"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  ok "systemd user session"
else
  bad "systemd --user not available (log in with a user session, not only SSH without linger)"
fi

UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service"
if [[ -f "$UNIT" ]]; then
  ok "hermes-gateway.service found"
else
  bad "hermes-gateway.service missing — run: hermes gateway service install --replace"
fi

if python3 -c "import tkinter" 2>/dev/null; then
  ok "python3 + tkinter"
else
  bad "tkinter missing — install python3-tk (Debian/Ubuntu) or python3-tkinter (Fedora)"
fi

for cmd in curl flock ss journalctl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    note_warn "$cmd not found (some features degraded)"
  fi
done

if command -v lsof >/dev/null 2>&1; then
  ok "lsof (Discord zombie-socket check)"
else
  note_warn "lsof optional — Discord health check is less accurate without it"
fi

if [[ -n "${HERMES_VENV_PY:-}" && -x "$HERMES_VENV_PY" ]]; then
  ok "Hermes venv python: $HERMES_VENV_PY"
else
  note_warn "HERMES_VENV_PY not found — aiohttp-socks may need manual install for SOCKS proxy"
fi

resolve_proxy_urls
if [[ "$HERMES_PROXY_MODE" == "on" ]]; then
  ok "proxy mode: on ($DISCORD_PROXY / $HTTP_PROXY)"
else
  ok "proxy mode: off (direct Discord — fine if not region-blocked)"
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
  echo "Preflight FAILED — fix items above before ./install.sh"
  exit 1
fi
if [[ "$has_warn" -gt 0 ]]; then
  echo "Preflight passed with warnings."
else
  echo "Preflight passed."
fi
