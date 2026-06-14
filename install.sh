#!/usr/bin/env bash
# Install Hermes Console (desktop entry + optional gateway hooks).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PY="$DIR/hermes_console.py"

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Options:
  --with-proxy       Enable proxy in systemd drop-in (SOCKS for Discord WS)
  --skip-proxy       Force no proxy (direct Discord)
  --auto-proxy       Enable proxy only if a local proxy port is listening (default)
  --proxy-port PORT  Local mixed/SOCKS port (e.g. 7897, 7890)
  --preflight        Run checks only, do not install
  -h, --help         Show this help

Environment (alternative to flags):
  HERMES_HOME          Hermes data dir (default: from systemd unit or ~/.hermes)
  HERMES_WITH_PROXY=1  Same as --with-proxy
  HERMES_SKIP_PROXY=1  Same as --skip-proxy
  HERMES_AUTO_PROXY=1  Same as --auto-proxy
  HERMES_PROXY_PORT    Local proxy port
  HERMES_HTTP_PROXY    Full HTTP proxy URL
  HERMES_DISCORD_PROXY Full SOCKS/HTTP URL for Discord WebSocket

Examples:
  ./install.sh                          # auto-detect proxy; safe default
  ./install.sh --skip-proxy               # US/EU direct Discord
  HERMES_PROXY_PORT=7890 ./install.sh --with-proxy
EOF
}

PREFLIGHT_ONLY=0
export HERMES_AUTO_PROXY="${HERMES_AUTO_PROXY:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-proxy)  export HERMES_WITH_PROXY=1; HERMES_AUTO_PROXY=0 ;;
    --skip-proxy)  export HERMES_SKIP_PROXY=1; HERMES_AUTO_PROXY=0 ;;
    --auto-proxy)  HERMES_AUTO_PROXY=1; unset HERMES_SKIP_PROXY HERMES_WITH_PROXY ;;
    --proxy-port)  shift; export HERMES_PROXY_PORT="${1:?port required}" ;;
    --preflight)   PREFLIGHT_ONLY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done
export HERMES_AUTO_PROXY

bash "$DIR/scripts/preflight.sh"
[[ "$PREFLIGHT_ONLY" == "1" ]] && exit 0

# shellcheck source=hermes_detect.sh
source "$DIR/hermes_detect.sh"

chmod +x "$APP_PY" "$DIR/install.sh" "$DIR/hermes_gateway_restart.sh" "$DIR/hermes_install_gateway_hooks.sh" "$DIR/hermes_health.py"

bash "$DIR/hermes_install_gateway_hooks.sh"
bash "$DIR/scripts/install_watch.sh"

DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/hermes-console.desktop"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
ICON_FILE="$ICON_DIR/hermes-console.svg"

mkdir -p "$DESKTOP_DIR" "$ICON_DIR"
cp "$DIR/assets/hermes-console.svg" "$ICON_FILE"

cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Hermes Console
Name[zh_CN]=Hermes 控制台
Comment=Restart Hermes Gateway and fix Discord reconnect
Comment[zh_CN]=重启 Hermes Gateway，修复 Discord 重连
Exec=/usr/bin/env python3 "$APP_PY"
Icon=$ICON_FILE
Terminal=false
Categories=Utility;Network;
StartupNotify=true
Keywords=hermes;discord;gateway;ai;
EOF

chmod +x "$DESKTOP_FILE"
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

resolve_proxy_urls
echo ""
echo "Hermes Console installed."
echo "  App menu:    Hermes 控制台"
echo "  CLI:         python3 \"$APP_PY\""
echo "  HERMES_HOME: $HERMES_HOME"
echo "  Proxy mode:  $HERMES_PROXY_MODE"
echo ""
echo "Uninstall: bash \"$DIR/uninstall.sh\""
