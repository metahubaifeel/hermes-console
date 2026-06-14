#!/usr/bin/env python3
"""Hermes Gateway health checks + desktop notifications."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "hermes-console"
STATE_FILE = CACHE_DIR / "health_state.json"

_DISCORD_ERROR_NEEDLES = (
    "Cannot connect to host gateway",
    "discord.client: Attempting a reconnect",
    "ClientConnectorError",
    "Connection timeout to host wss://gateway",
    "ConnectionResetError",
)

_APPROVAL_NEEDLES = (
    "waiting for user approval",
    "approval_pending",
    "Failed to send approval request",
    "Button-based approval failed",
    "pending_approval",
)

_NOTIFY_COOLDOWN_SEC = int(os.environ.get("HERMES_NOTIFY_COOLDOWN", "300"))
_AUTO_REPAIR_COOLDOWN_SEC = int(os.environ.get("HERMES_AUTO_REPAIR_COOLDOWN", "900"))
_AUTO_REPAIR_AFTER = int(os.environ.get("HERMES_AUTO_REPAIR_AFTER", "2"))
ROOT = Path(__file__).resolve().parent
RESTART_SH = ROOT / "hermes_gateway_restart.sh"


def _resolve_hermes_home() -> Path:
    env = os.environ.get("HERMES_HOME")
    if env:
        return Path(env)
    unit = Path.home() / ".config/systemd/user/hermes-gateway.service"
    if unit.is_file():
        import re

        for line in unit.read_text(encoding="utf-8").splitlines():
            m = re.match(r'^Environment="HERMES_HOME=(.+)"$', line)
            if m:
                return Path(m.group(1))
    return Path.home() / ".hermes"


HERMES_HOME = _resolve_hermes_home()


def _run(cmd: list[str], *, timeout: float = 8) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except (subprocess.TimeoutExpired, OSError):
        return 1, ""


def gateway_active() -> bool:
    code, out = _run(["systemctl", "--user", "is-active", "hermes-gateway.service"], timeout=5)
    return code == 0 and out.strip() == "active"


def gateway_pid() -> int | None:
    code, out = _run(
        ["systemctl", "--user", "show", "hermes-gateway.service", "-p", "MainPID", "--value"],
        timeout=5,
    )
    if code != 0:
        return None
    try:
        pid = int(out.strip())
    except ValueError:
        return None
    return pid if pid > 0 else None


def discord_state() -> tuple[str | None, str | None]:
    state_file = HERMES_HOME / "gateway_state.json"
    try:
        data = json.loads(state_file.read_text(encoding="utf-8"))
        plat = (data.get("platforms") or {}).get("discord") or {}
        state = plat.get("state")
        updated_at = plat.get("updated_at")
        return (state if isinstance(state, str) else None), (
            updated_at if isinstance(updated_at, str) else None
        )
    except (OSError, json.JSONDecodeError, AttributeError):
        return None, None


def gateway_has_zombie_sockets() -> bool:
    pid = gateway_pid()
    if not pid:
        return False
    code, _ = _run(["bash", "-c", "command -v lsof >/dev/null"], timeout=2)
    if code != 0:
        return False
    code, out = _run(["lsof", "-nP", "-p", str(pid), "-a", "-iTCP"], timeout=3)
    return code == 0 and "CLOSE_WAIT" in out


def journal_has_needles(since: str, needles: tuple[str, ...]) -> bool:
    cmd = [
        "journalctl",
        "--user",
        "-u",
        "hermes-gateway.service",
        "--no-pager",
        "-n",
        "150",
        "--since",
        since,
    ]
    code, out = _run(cmd, timeout=6)
    return code == 0 and bool(out) and any(n in out for n in needles)


def gateway_state_pid_matches() -> bool:
    live = gateway_pid()
    if not live:
        return False
    try:
        data = json.loads((HERMES_HOME / "gateway_state.json").read_text(encoding="utf-8"))
        return int(data.get("pid") or 0) == live
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return False


def discord_live_ok() -> bool:
    state, updated_at = discord_state()
    if state != "connected":
        return False
    if not gateway_state_pid_matches():
        return False
    if gateway_has_zombie_sockets():
        return False
    if journal_has_needles(updated_at or "15 min ago", _DISCORD_ERROR_NEEDLES):
        return False
    return True


def approval_pending() -> bool:
    return journal_has_needles("20 min ago", _APPROVAL_NEEDLES)


def assess_health() -> tuple[bool, str, str, str]:
    """Return (gateway_running, gateway_text, discord_text, discord_color)."""
    gw = gateway_active()
    if not gw:
        return False, "Gateway：✗ 未运行", "Discord：—", "#c33"

    if discord_live_ok():
        extra = ""
        if approval_pending():
            extra = "；⚠ 有待批准命令"
        return True, "Gateway：✓ 运行中", f"Discord：✓ 可对话{extra}", "#0a7"

    state, _ = discord_state()
    if state == "connected":
        return (
            True,
            "Gateway：✓ 运行中",
            "Discord：⚠ 假连接（点「修复并重连」）",
            "#c90",
        )
    if state == "retrying":
        return True, "Gateway：✓ 运行中", "Discord：✗ 重连失败（勿连点，等 1 分钟）", "#c33"
    if state == "connecting":
        return True, "Gateway：✓ 运行中", "Discord：连接中…", "#c90"
    if state == "disconnected":
        return True, "Gateway：✓ 运行中", "Discord：✗ 已断开", "#c33"
    if state is None:
        return True, "Gateway：✓ 运行中", "Discord：✗ 未连接（等待或修复）", "#c33"
    return True, "Gateway：✓ 运行中", "Discord：—", "#888"


def health_snapshot() -> dict:
    gw, gw_text, dc_text, _ = assess_health()
    level = "ok"
    issues: list[str] = []

    if not gw:
        level = "critical"
        issues.append("Gateway 未运行")
    elif not discord_live_ok():
        level = "critical" if discord_state()[0] in ("disconnected", "retrying", None) else "warn"
        issues.append(dc_text.replace("Discord：", "Discord "))

    if approval_pending():
        if level == "ok":
            level = "warn"
        issues.append("有命令等你批准（请看 Discord）")

    return {
        "level": level,
        "gateway_running": gw,
        "discord_live": discord_live_ok() if gw else False,
        "approval_pending": approval_pending(),
        "issues": issues,
        "gateway_text": gw_text,
        "discord_text": dc_text,
    }


def _load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_state(data: dict) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def notify(title: str, body: str, *, urgency: str = "normal") -> bool:
    if os.environ.get("HERMES_NOTIFY") == "0":
        return False
    if not _run(["bash", "-c", "command -v notify-send >/dev/null"], timeout=2)[0] == 0:
        return False
    args = ["notify-send", "-a", "Hermes Console", "-i", "dialog-warning"]
    if urgency == "critical":
        args.extend(["-u", "critical"])
    args.extend([title, body])
    code, _ = _run(args, timeout=5)
    return code == 0


def _try_auto_repair(prev: dict, snap: dict, now: float) -> bool:
    """Run repair script when Discord stays broken. Returns True if repair started."""
    if os.environ.get("HERMES_AUTO_REPAIR", "1") == "0":
        return False
    if snap.get("approval_pending"):
        return False
    if snap.get("discord_live"):
        return False
    if not RESTART_SH.is_file():
        return False

    streak = int(prev.get("bad_streak", 0)) + 1
    prev["bad_streak"] = streak
    if streak < _AUTO_REPAIR_AFTER:
        return False

    last = float(prev.get("last_auto_repair", 0))
    if (now - last) < _AUTO_REPAIR_COOLDOWN_SEC:
        return False

    notify(
        "Hermes 正在自动修复 Discord",
        "检测到 Discord 不可用（假连接或已断开），正在自动修复并重连，约 1–2 分钟…",
        urgency="critical",
    )
    prev["last_auto_repair"] = now
    prev["bad_streak"] = 0
    try:
        subprocess.run(
            ["bash", str(RESTART_SH), "console"],
            timeout=300,
            capture_output=True,
            text=True,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass
    return True


def watch_once(*, force: bool = False) -> dict:
    """Check health; notify and optionally auto-repair. Returns snapshot."""
    snap = health_snapshot()
    prev = _load_state()
    import time

    now = time.time()

    if snap["discord_live"]:
        prev["bad_streak"] = 0
    elif not snap.get("approval_pending"):
        _try_auto_repair(prev, snap, now)

    key = snap["level"] + "|" + "|".join(snap["issues"])
    prev_key = prev.get("key", "")
    prev_notify = float(prev.get("last_notify", 0))
    cooldown_ok = (now - prev_notify) >= _NOTIFY_COOLDOWN_SEC

    should_notify = False
    title = "Hermes 需要留意"
    body = ""

    if snap["level"] == "critical":
        body = "；".join(snap["issues"]) or "Gateway / Discord 异常"
        if os.environ.get("HERMES_AUTO_REPAIR", "1") != "0":
            body += "。后台将在约 4 分钟内自动尝试修复（或手动点一次「修复并重连」）。"
        else:
            body += "。打开「Hermes 控制台」→ 修复并重连（勿连点）。"
        should_notify = force or (key != prev_key and cooldown_ok) or (
            snap["level"] != prev.get("level") and cooldown_ok
        )
        title = "Hermes：Discord 可能收不到消息"
    elif snap["level"] == "warn":
        body = "；".join(snap["issues"]) or "状态异常"
        if snap["approval_pending"]:
            body += "。去 Discord 点批准按钮，否则任务会卡住。"
        elif "假连接" in snap.get("discord_text", ""):
            body += "。合盖/网络抖后常见，后台会自动尝试修复。"
        should_notify = force or (key != prev_key and cooldown_ok)

    if should_notify and body:
        notify(title, body, urgency="critical" if snap["level"] == "critical" else "normal")
        prev["last_notify"] = now

    prev.update({"key": key, "level": snap["level"], "issues": snap["issues"], "checked_at": now})
    _save_state(prev)
    return snap


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print("Usage: hermes_health.py [--watch | --json | --quiet]")
        return 0
    if argv[0] == "--watch":
        snap = watch_once(force="--force" in argv)
        if "--json" in argv:
            print(json.dumps(snap, ensure_ascii=False, indent=2))
        elif snap["level"] != "ok":
            print(snap["level"], "—", "；".join(snap["issues"]))
        return 0 if snap["level"] == "ok" else 1
    if argv[0] == "--json":
        print(json.dumps(health_snapshot(), ensure_ascii=False, indent=2))
        return 0
    snap = health_snapshot()
    print(snap["level"], snap["gateway_text"], snap["discord_text"])
    return 0 if snap["level"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
