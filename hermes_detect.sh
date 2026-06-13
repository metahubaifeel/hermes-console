#!/usr/bin/env bash
# Detect HERMES_HOME, venv python, and optional proxy settings.
# No hardcoded user paths — reads systemd unit or env only.
set -euo pipefail

UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service"
DROPIN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service.d/hermes-fixes.conf"

if [[ -z "${HERMES_HOME:-}" ]]; then
  env_from_unit=""
  if [[ -f "$UNIT_FILE" ]]; then
    env_from_unit="$(grep -E '^Environment="HERMES_HOME=' "$UNIT_FILE" 2>/dev/null | head -1 | sed -E 's/^Environment="HERMES_HOME=([^"]+)".*/\1/')"
  fi
  HERMES_HOME="${env_from_unit:-$HOME/.hermes}"
fi
export HERMES_HOME

if [[ -z "${HERMES_VENV_PY:-}" ]]; then
  exec_start=""
  if [[ -f "$UNIT_FILE" ]]; then
    exec_start="$(grep -E '^ExecStart=' "$UNIT_FILE" 2>/dev/null | head -1 | sed -E 's/^ExecStart=//' | tr -d '"')"
  fi
  if [[ "$exec_start" =~ ^([^[:space:]]+/venv/bin/python) ]]; then
    HERMES_VENV_PY="${BASH_REMATCH[1]}"
  elif [[ -d "$HERMES_HOME/../hermes-agent/venv/bin" ]]; then
    HERMES_VENV_PY="$(cd "$HERMES_HOME/../hermes-agent/venv/bin" && pwd)/python"
  fi
fi
export HERMES_VENV_PY

# HERMES_PROXY_PORT is canonical; HERMES_CLASH_PORT is a backward-compatible alias.
HERMES_PROXY_PORT="${HERMES_PROXY_PORT:-${HERMES_CLASH_PORT:-}}"
export HERMES_PROXY_PORT

_local_port_listening() {
  local port="$1"
  ss -ltn 2>/dev/null | grep -q ":${port} " || \
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:${port}"
}

_detect_local_proxy_port() {
  local port
  if [[ -n "${HERMES_PROXY_PORT:-}" ]]; then
    echo "$HERMES_PROXY_PORT"
    return 0
  fi
  for port in 7897 7890 10808 1080 8080; do
    if _local_port_listening "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# Resolve whether install/restart should use proxy env.
# Modes: off | on
resolve_proxy_mode() {
  if [[ -n "${HERMES_SKIP_PROXY:-}" ]]; then
    HERMES_PROXY_MODE=off
    return 0
  fi
  if [[ -n "${HERMES_HTTP_PROXY:-}" || -n "${HERMES_DISCORD_PROXY:-}" || "${HERMES_WITH_PROXY:-}" == "1" ]]; then
    HERMES_PROXY_MODE=on
    return 0
  fi
  if [[ -f "$DROPIN_FILE" ]] && grep -q 'DISCORD_PROXY=' "$DROPIN_FILE" 2>/dev/null; then
    HERMES_PROXY_MODE=on
    return 0
  fi
  if [[ "${HERMES_AUTO_PROXY:-}" == "1" ]] && _detect_local_proxy_port >/dev/null; then
    HERMES_PROXY_MODE=on
    return 0
  fi
  HERMES_PROXY_MODE=off
}

resolve_proxy_urls() {
  resolve_proxy_mode
  if [[ "$HERMES_PROXY_MODE" != "on" ]]; then
    HTTP_PROXY=""
    DISCORD_PROXY=""
    export HTTP_PROXY DISCORD_PROXY HERMES_PROXY_MODE
    return 0
  fi

  local port
  port="$(_detect_local_proxy_port 2>/dev/null || true)"
  port="${port:-7897}"

  HTTP_PROXY="${HERMES_HTTP_PROXY:-http://127.0.0.1:${port}}"
  DISCORD_PROXY="${HERMES_DISCORD_PROXY:-socks5://127.0.0.1:${port}}"
  export HTTP_PROXY DISCORD_PROXY HERMES_PROXY_MODE
}
