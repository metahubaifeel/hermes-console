#!/usr/bin/env bash
# Install systemd drop-in + wake-on-resume. Proxy is optional, never forced.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RESTART_SH="$DIR/hermes_gateway_restart.sh"
DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service.d"
DROPIN_FILE="$DROPIN_DIR/hermes-fixes.conf"
WAKE_SVC="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway-wake.service"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service"

# shellcheck source=hermes_detect.sh
source "$DIR/hermes_detect.sh"

ENV_FILE="$HERMES_HOME/.env"

chmod +x "$RESTART_SH" "$DIR/hermes_install_gateway_hooks.sh" "$DIR/install.sh" "$DIR/hermes_console.py"

if [[ ! -f "$UNIT_FILE" ]]; then
  echo "ERROR: hermes-gateway.service not found."
  echo "Install Hermes Gateway first:"
  echo "  hermes gateway service install --replace"
  echo "  systemctl --user enable --now hermes-gateway.service"
  exit 1
fi

mkdir -p "$DROPIN_DIR" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" "$HERMES_HOME"

resolve_proxy_urls

# aiohttp-socks only needed when using SOCKS proxy for Discord WebSocket.
if [[ "$HERMES_PROXY_MODE" == "on" && -n "${HERMES_VENV_PY:-}" && -x "$HERMES_VENV_PY" ]]; then
  "$HERMES_VENV_PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$HERMES_VENV_PY" -m pip install -q aiohttp-socks 2>/dev/null || true
fi

# Sync proxy keys to .env only when proxy mode is on; never delete user's other keys.
if [[ "$HERMES_PROXY_MODE" == "on" ]]; then
  touch "$ENV_FILE"
  for kv in "DISCORD_PROXY=$DISCORD_PROXY" "HTTP_PROXY=$HTTP_PROXY" "HTTPS_PROXY=$HTTP_PROXY"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^${key}=.*|${kv}|" "$ENV_FILE"
    else
      echo "$kv" >>"$ENV_FILE"
    fi
  done
fi

# Drop-in survives `hermes gateway service install --replace` (Hermes does not remove .d/).
{
  echo "[Service]"
  if [[ "$HERMES_PROXY_MODE" == "on" ]]; then
    echo "Environment=\"DISCORD_PROXY=$DISCORD_PROXY\""
    echo "Environment=\"HTTP_PROXY=$HTTP_PROXY\""
    echo "Environment=\"HTTPS_PROXY=$HTTP_PROXY\""
    echo "Environment=\"ALL_PROXY=$DISCORD_PROXY\""
    echo "Environment=\"NO_PROXY=localhost,127.0.0.1,127.0.0.0/8\""
  fi
  cat <<'EOF'
Environment="HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT=90"
Environment="HERMES_DISCORD_READY_TIMEOUT=90"
KillMode=control-group
TimeoutStopSec=210
EOF
} >"$DROPIN_FILE"

cat >"$WAKE_SVC" <<EOF
[Unit]
Description=Restart Hermes Gateway after sleep/resume (hermes-console)
After=suspend.target hibernate.target hybrid-sleep.target sleep.target

[Service]
Type=oneshot
Environment="HERMES_HOME=$HERMES_HOME"
ExecStart=$RESTART_SH wake
TimeoutStartSec=240

[Install]
WantedBy=suspend.target
EOF

systemctl --user daemon-reload
systemctl --user enable hermes-gateway.service 2>/dev/null || true
systemctl --user enable hermes-gateway-wake.service 2>/dev/null || true

echo "Installed gateway hooks:"
echo "  HERMES_HOME:   $HERMES_HOME"
echo "  Proxy mode:    $HERMES_PROXY_MODE"
if [[ "$HERMES_PROXY_MODE" == "on" ]]; then
  echo "  DISCORD_PROXY: $DISCORD_PROXY"
  echo "  HTTP_PROXY:    $HTTP_PROXY"
fi
echo "  Drop-in:       $DROPIN_FILE"
echo "  Wake service:  $WAKE_SVC"
echo "  Restart:       $RESTART_SH"
echo ""
echo "Repair Discord: bash \"$RESTART_SH\" console"
