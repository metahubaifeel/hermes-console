#!/usr/bin/env bash
set -euo pipefail

DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/hermes-console.desktop"
ICON_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hermes-console.svg"
WAKE_SVC="$HOME/.config/systemd/user/hermes-gateway-wake.service"

rm -f "$DESKTOP_FILE" "$ICON_FILE"
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" 2>/dev/null || true

systemctl --user disable hermes-gateway-wake.service 2>/dev/null || true
rm -f "$WAKE_SVC"
systemctl --user daemon-reload 2>/dev/null || true

echo "Removed desktop entry and wake service."
echo "Proxy drop-in was NOT removed (may still be useful). To remove:"
echo "  rm ~/.config/systemd/user/hermes-gateway.service.d/hermes-fixes.conf"
echo "  systemctl --user daemon-reload"
