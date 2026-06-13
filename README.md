# Hermes Console

**Desktop console + systemd helpers for [Hermes Agent](https://github.com/NousResearch/hermes-agent) Gateway (Discord reconnect, MCP restart, sleep/resume).**

[中文说明](#背景) · [AGENTS.md](AGENTS.md) (for AI coding agents) · MIT License

![Platform](https://img.shields.io/badge/platform-Linux-blue)
![Python](https://img.shields.io/badge/python-3.10+-green)

> **For AI agents:** read [AGENTS.md](AGENTS.md) before installing or modifying this repo.

---

## Who is this for?

- You run **Hermes Gateway** with **Discord** on **Linux** (systemd user service)
- Optional: laptop sleep/lid-close breaks Discord; optional: local proxy for region-blocked networks
- **Not** tied to any specific machine, username, or Clash port — proxy is **opt-in**

## Quick install

```bash
git clone https://github.com/YOUR_USERNAME/hermes-console.git
cd hermes-console

# Check prerequisites (no changes made)
./install.sh --preflight

# Pick ONE:
./install.sh --skip-proxy    # direct Discord (US/EU, no proxy)
./install.sh                 # auto: proxy only if local port is listening
./install.sh --with-proxy    # force SOCKS/HTTP proxy drop-in
```

Prerequisite: Hermes Gateway user service must exist:

```bash
hermes gateway service install --replace
systemctl --user enable --now hermes-gateway.service
```

## Install options

| Command | Proxy in drop-in | When to use |
|---------|------------------|-------------|
| `./install.sh --skip-proxy` | No | Discord reachable directly |
| `./install.sh` (default) | Auto if port 7897/7890/… listening, or keep existing drop-in | Most flexible |
| `./install.sh --with-proxy` | Yes | Region-blocked; set `HERMES_PROXY_PORT` if not 7897 |
| `HERMES_HOME=/path ./install.sh` | — | Non-default Hermes data dir |

See [env.example](env.example) for all environment variables.

## What gets installed

1. **Desktop app** — `Hermes 控制台` → `hermes_console.py`
2. **systemd drop-in** — `~/.config/systemd/user/hermes-gateway.service.d/hermes-fixes.conf`  
   Merged with Hermes' main unit; **survives** `hermes gateway service install --replace`
3. **Wake service** — restarts Gateway after suspend/resume

### What is a drop-in?

Hermes writes the main unit file and may overwrite it. A **drop-in** is a patch file systemd merges on start — we put proxy (optional) and connect timeouts there so they are not lost.

## Features

- **Restart Gateway** — reload MCP / `config.yaml` (~10s)
- **Fix & reconnect** — wait for network, restart, wait for Discord (~30–120s)
- **Live Discord health** — detects fake "connected" after sleep
- **flock** — prevents double-click restart storms

## Requirements

- Linux, systemd user session (`loginctl enable-linger $USER` if headless)
- Python 3.10+ with tkinter
- `curl`, `flock`, `ss`, `journalctl` (standard on most distros)
- `lsof` optional (better Discord health check)

## Troubleshooting

```bash
./install.sh --preflight
journalctl --user -u hermes-gateway.service -n 30 --no-pager
bash hermes_gateway_restart.sh console
```

**Do not click "Fix & reconnect" repeatedly** — each click SIGKILLs mid-connect.

## Uninstall

```bash
./uninstall.sh
```

---

## 背景

给 [Hermes Agent](https://github.com/NousResearch/hermes-agent) Gateway 用的 Linux 小工具：Discord 合盖假连接、MCP 改配置要重启、代理环境 WebSocket 问题。  
**无硬编码路径**；代理默认不强制，适合开源给不同环境的人用。

## Agent / 自动化

仓库根目录 [AGENTS.md](AGENTS.md) 给 Cursor、Copilot 等 agent 用：安装顺序、代理规则、禁止硬编码、排错命令。

## License

MIT — see [LICENSE](LICENSE)
