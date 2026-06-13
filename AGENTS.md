# AGENTS.md — instructions for coding agents (Cursor, Copilot, Claude, etc.)

This file helps AI agents install, modify, and debug **hermes-console** without breaking user systems.

## What this project is

**hermes-console** is a small Linux companion for [Hermes Agent](https://github.com/NousResearch/hermes-agent) Gateway:

- Tk GUI (`hermes_console.py`) — restart Gateway, fix Discord after sleep
- Bash scripts — systemd drop-in, wake-on-resume, reliable restart
- **Not** part of Hermes upstream; community tooling

## Hard requirements (do not assume)

| Requirement | Notes |
|-------------|--------|
| **Linux** | Uses systemd **user** units only |
| **Hermes Gateway installed** | `hermes gateway service install --replace` must exist first |
| **Python 3.10+** | With **tkinter** (`python3-tk` on Debian/Ubuntu) |
| **No hardcoded paths** | Never add `/home/...` or username-specific paths |

## What is NOT required

- Clash / V2Ray / proxy — **optional**, only for region-blocked Discord
- K10 board / DFRobot — **not** part of this repo (legacy names removed)
- Root / sudo — everything is `--user` systemd

## Install workflow (for agents helping users)

```bash
git clone <repo-url> hermes-console && cd hermes-console

# 1. Always preflight first
./install.sh --preflight

# 2a. Direct Discord (US/EU, no proxy)
./install.sh --skip-proxy

# 2b. Behind local proxy (auto-detect port 7897/7890/… if listening)
./install.sh

# 2c. Force proxy on specific port
HERMES_PROXY_PORT=7890 ./install.sh --with-proxy

# 3. Custom HERMES_HOME (if not in systemd unit)
HERMES_HOME=/path/to/.hermes ./install.sh
```

**Never** tell users to edit systemd main unit for proxy — use drop-in only:
`~/.config/systemd/user/hermes-gateway.service.d/hermes-fixes.conf`

## Proxy rules (critical)

1. **Discord WebSocket** (`wss://gateway.discord.gg`) often fails through **HTTP-only** proxy.
2. Use **SOCKS5** for `DISCORD_PROXY` when proxy is needed: `socks5://127.0.0.1:PORT`
3. Install `aiohttp-socks` in Hermes venv when SOCKS is enabled (install script does this).
4. **Do not force proxy** on users without region blocks — default `--auto-proxy` only enables if a local port is listening, or preserve existing drop-in.

## File map

```
hermes_console.py              # GUI
hermes_gateway_restart.sh      # restart / repair CLI
hermes_install_gateway_hooks.sh # drop-in + wake service
hermes_detect.sh               # HERMES_HOME, venv, proxy resolution (source only)
install.sh                     # entry point + flags
scripts/preflight.sh           # pre-install checks
env.example                    # documented env vars
```

## Common user issues

| Symptom | Likely cause | Agent action |
|---------|--------------|--------------|
| Discord 连接中 forever | Proxy flaky or wrong type | Check drop-in SOCKS; test `curl --proxy socks5h://127.0.0.1:PORT https://discord.com/api/v10/gateway` |
| 连点修复没回复 | SIGKILL mid-connect | Tell user: wait 1–2 min, click once |
| 假连接 | Sleep killed WS, stale state file | Use console health check or `bash hermes_gateway_restart.sh console` |
| install fails | No hermes-gateway.service | Run Hermes gateway install first |
| tkinter error | Missing python3-tk | Install distro package, not pip |

## Debugging commands

```bash
systemctl --user status hermes-gateway.service
journalctl --user -u hermes-gateway.service -n 50 --no-pager
python3 -c "import json; print(json.load(open('$HERMES_HOME/gateway_state.json'))['platforms'])"
bash hermes_gateway_restart.sh console
```

## Code change guidelines for agents

1. **No hardcoded paths** — use `hermes_detect.sh` or env vars.
2. **Proxy opt-in** — `HERMES_SKIP_PROXY`, `HERMES_WITH_PROXY`, `HERMES_AUTO_PROXY`.
3. **Preserve existing drop-in** on reinstall when proxy was already configured.
4. **Keep install idempotent** — safe to run `./install.sh` multiple times.
5. **UI strings** may be Chinese; **install/log output** should be English for international users.
6. Do not commit user tokens, `.env` with secrets, or `HERMES_HOME` paths from a specific machine.

## Testing before PR

```bash
shellcheck hermes_*.sh install.sh scripts/preflight.sh
./install.sh --preflight
python3 -m py_compile hermes_console.py
```

## Uninstall

```bash
./uninstall.sh
# drop-in removal is manual (documented in uninstall.sh output)
```

## Related Hermes upstream (outside this repo)

Some Discord timeout/proxy fixes may live in **hermes-agent** source (`gateway/platforms/base.py`, discord adapter). This repo only manages **systemd + GUI + restart** — do not duplicate upstream patches here unless they are shell/env only.
