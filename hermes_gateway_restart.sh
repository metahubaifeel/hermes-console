#!/usr/bin/env bash
# Reliable Hermes Gateway restart — console, wake-on-resume, CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hermes_detect.sh
source "$SCRIPT_DIR/hermes_detect.sh"
resolve_proxy_urls

STATE_FILE="$HERMES_HOME/gateway_state.json"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/hermes-gateway-restart.lock"
REASON="${1:-manual}"
DISCORD_WAIT_SEC="${HERMES_DISCORD_WAIT_SEC:-180}"
NETWORK_WAIT_SEC="${HERMES_NETWORK_WAIT_SEC:-90}"

log() { echo "[hermes-restart] $*"; }

wait_local_proxy() {
  [[ "$HERMES_PROXY_MODE" == "on" ]] || return 0
  local port="${HERMES_PROXY_PORT:-}"
  if [[ -z "$port" && "$HTTP_PROXY" =~ :([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  fi
  [[ -n "$port" ]] || return 0

  log "Waiting for local proxy port ${port}…"
  local i
  for ((i = 1; i <= 30; i++)); do
    if ss -ltn 2>/dev/null | grep -q ":${port} "; then
      return 0
    fi
    sleep 1
  done
  log "WARN: port ${port} not listening (continuing anyway)"
  return 0
}

wait_network() {
  if [[ "$REASON" == wake ]]; then
    log "After resume: waiting 15s for network…"
    sleep 15
  fi
  wait_local_proxy
  log "Checking Discord API reachability (up to ${NETWORK_WAIT_SEC}s)…"
  local i
  for ((i = 1; i <= NETWORK_WAIT_SEC / 3; i++)); do
    if [[ "$HERMES_PROXY_MODE" == "on" ]]; then
      curl -sf --connect-timeout 4 --proxy "$DISCORD_PROXY" https://discord.com/api/v10/gateway >/dev/null 2>&1 && { log "Network OK (SOCKS)"; return 0; }
      curl -sf --connect-timeout 4 -x "$HTTP_PROXY" https://discord.com/api/v10/gateway >/dev/null 2>&1 && { log "Network OK (HTTP proxy)"; return 0; }
    fi
    curl -sf --connect-timeout 4 https://discord.com/api/v10/gateway >/dev/null 2>&1 && { log "Network OK (direct)"; return 0; }
    sleep 3
  done
  log "WARN: Discord API unreachable; starting Gateway anyway"
  return 0
}

discord_connected() {
  python3 - <<PY
import json, sys
from pathlib import Path
p = Path(${STATE_FILE@Q})
if not p.is_file():
    sys.exit(1)
d = json.loads(p.read_text())
if d.get("gateway_state") != "running":
    sys.exit(1)
dc = (d.get("platforms") or {}).get("discord") or {}
sys.exit(0 if dc.get("state") == "connected" else 1)
PY
}

wait_discord() {
  log "Waiting for Discord (up to ${DISCORD_WAIT_SEC}s, includes MCP startup)…"
  local i max=$((DISCORD_WAIT_SEC / 3))
  for ((i = 1; i <= max; i++)); do
    if discord_connected; then
      log "Discord connected"
      return 0
    fi
    sleep 3
  done
  return 1
}

gateway_running() {
  systemctl --user is-active --quiet hermes-gateway.service
}

do_restart() {
  local wait_discord_after="${1:-1}"
  log "Stopping Gateway (${REASON})…"
  systemctl --user kill -s SIGKILL hermes-gateway.service 2>/dev/null || true
  sleep 2
  systemctl --user reset-failed hermes-gateway.service 2>/dev/null || true
  systemctl --user daemon-reload

  log "Starting Gateway…"
  systemctl --user start hermes-gateway.service

  local i
  for ((i = 1; i <= 45; i++)); do
    gateway_running && break
    sleep 1
  done

  if ! gateway_running; then
    log "ERROR: Gateway failed to start"
    return 1
  fi

  if [[ "$wait_discord_after" != "1" ]]; then
    log "Done: Gateway restarted (MCP/config reload)"
    return 0
  fi

  if wait_discord; then
    log "Done: Gateway running, Discord connected"
    return 0
  fi

  log "WARN: Gateway up but Discord not connected"
  journalctl --user -u hermes-gateway.service -n 8 --no-pager 2>/dev/null | grep -iE "discord|proxy|timeout" || true
  return 2
}

main() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Restart already in progress, skipping"
    exit 0
  fi
  case "$REASON" in
    restart|mcp|reload)
      do_restart 0
      ;;
    *)
      wait_network
      do_restart 1
      ;;
  esac
}

main "$@"
