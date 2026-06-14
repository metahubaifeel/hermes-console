#!/usr/bin/env bash
# Install systemd user timer for health checks + desktop notifications.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../hermes_detect.sh
source "$DIR/hermes_detect.sh"

HEALTH_PY="$DIR/hermes_health.py"
SVC="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-console-watch.service"
TMR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-console-watch.timer"

chmod +x "$HEALTH_PY"

cat >"$SVC" <<EOF
[Unit]
Description=Hermes Console health check and desktop notification

[Service]
Type=oneshot
Environment="HERMES_HOME=$HERMES_HOME"
Environment="HERMES_AUTO_REPAIR=1"
ExecStart=/usr/bin/env python3 "$HEALTH_PY" --watch
EOF

cat >"$TMR" <<EOF
[Unit]
Description=Run Hermes health check every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now hermes-console-watch.timer

echo "Health watch enabled (every 2 min, desktop notify on issues)."
echo "  Timer:  hermes-console-watch.timer"
echo "  Test:   python3 \"$HEALTH_PY\" --watch --force"
echo "  Disable: systemctl --user disable --now hermes-console-watch.timer"
