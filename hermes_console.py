#!/usr/bin/env python3
"""Hermes Gateway Console — one-click restart and Discord reconnect for daily use."""
from __future__ import annotations

import os
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, scrolledtext, ttk

from hermes_health import HERMES_HOME, assess_health, discord_live_ok

ROOT = Path(__file__).resolve().parent
RESTART_SH = ROOT / "hermes_gateway_restart.sh"


def _run(cmd: list[str] | str, *, timeout: float = 180, shell: bool = False) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=shell,
            env={**os.environ, "HERMES_HOME": str(HERMES_HOME)},
        )
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, "操作超时"
    except Exception as e:
        return 1, str(e)


class LauncherApp:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("Hermes 控制台")
        self.root.geometry("520x500")
        self.root.minsize(440, 400)

        self._busy = False
        self._refreshing = False
        self._build_ui()
        self.root.after(50, lambda: self.refresh_status())

    def _build_ui(self) -> None:
        top = ttk.Frame(self.root, padding=12)
        top.pack(fill=tk.X)

        ttk.Label(top, text="Hermes 控制台", font=("", 16, "bold")).pack(anchor=tk.W)
        ttk.Label(
            top,
            text="改 MCP / config.yaml 后点「重启」；合盖后 Discord 不回消息点「修复并重连」。",
            wraplength=480,
        ).pack(anchor=tk.W, pady=(4, 8))

        self.lbl_hermes = ttk.Label(top, text="Gateway：检测中…")
        self.lbl_discord = ttk.Label(top, text="Discord：检测中…")
        self.lbl_hint = ttk.Label(
            top,
            text="后台每 2 分钟检查；异常会弹桌面通知。修复并重合约 30–120 秒。",
            foreground="#555",
        )
        for w in (self.lbl_hermes, self.lbl_discord, self.lbl_hint):
            w.pack(anchor=tk.W)

        btns = ttk.Frame(self.root, padding=(12, 0))
        btns.pack(fill=tk.X)

        row_main = ttk.Frame(btns)
        row_main.pack(fill=tk.X, pady=2)
        self.btn_restart = ttk.Button(row_main, text="🔄 重启 Gateway", command=self.restart_gateway)
        self.btn_restart.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 4))
        self.btn_fix = ttk.Button(row_main, text="🔧 修复并重连", command=self.fix_and_reconnect)
        self.btn_fix.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(4, 0))

        row = ttk.Frame(btns)
        row.pack(fill=tk.X, pady=2)
        self.btn_stop = ttk.Button(row, text="停止", command=self.stop_hermes)
        self.btn_stop.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 4))
        self.btn_refresh = ttk.Button(row, text="刷新状态", command=self.refresh_status)
        self.btn_refresh.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(4, 0))

        self._action_buttons = [self.btn_restart, self.btn_fix, self.btn_stop, self.btn_refresh]

        ttk.Label(self.root, text="最近日志", padding=(12, 8, 12, 0)).pack(anchor=tk.W)
        self.log = scrolledtext.ScrolledText(self.root, height=12, font=("Monospace", 9))
        self.log.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 12))
        self.log.configure(state=tk.DISABLED)

        self.root.after(8000, self._tick)

    def _tick(self) -> None:
        if not self._busy:
            self.refresh_status(quiet=True)
        self.root.after(8000, self._tick)

    def _append_log(self, msg: str) -> None:
        self.log.configure(state=tk.NORMAL)
        self.log.insert(tk.END, msg.rstrip() + "\n")
        self.log.see(tk.END)
        self.log.configure(state=tk.DISABLED)

    def _set_busy(self, busy: bool, *, hint: str | None = None) -> None:
        self._busy = busy
        state = tk.DISABLED if busy else tk.NORMAL
        for btn in self._action_buttons:
            btn.configure(state=state)
        if hint:
            self.lbl_hint.configure(text=hint, foreground="#06c" if busy else "#555")

    def _worker(self, title: str, fn, *, busy_hint: str) -> None:
        if self._busy:
            return

        def run() -> None:
            self.root.after(0, lambda: self._set_busy(True, hint=busy_hint))
            try:
                msg = fn()
                if msg:
                    self.root.after(0, lambda: self._append_log(msg))
            except Exception as e:
                self.root.after(0, lambda: messagebox.showerror(title, str(e)))
            finally:
                self.root.after(
                    0,
                    lambda: (
                        self._set_busy(
                            False,
                            hint="后台每 2 分钟检查；异常会弹桌面通知。修复并重合约 30–120 秒。",
                        ),
                        self.refresh_status(),
                    ),
                )

        threading.Thread(target=run, daemon=True).start()

    def refresh_status(self, *, quiet: bool = False) -> None:
        if self._busy or self._refreshing:
            return
        self._refreshing = True

        def work() -> None:
            health = assess_health()
            log_out: str | None = None
            if not quiet:
                code, out = _run(
                    [
                        "journalctl",
                        "--user",
                        "-u",
                        "hermes-gateway.service",
                        "-n",
                        "16",
                        "--no-pager",
                    ],
                    timeout=5,
                )
                if code == 0 and out:
                    log_out = out
            self.root.after(0, lambda: self._apply_refresh(health, log_out))

        threading.Thread(target=work, daemon=True).start()

    def _apply_refresh(self, health: tuple[bool, str, str, str], log_out: str | None) -> None:
        self._refreshing = False
        gw_running, gw_text, dc_text, dc_color = health
        self.lbl_hermes.configure(
            text=gw_text,
            foreground="#0a7" if gw_running else "#c33",
        )
        self.lbl_discord.configure(text=dc_text, foreground=dc_color)
        if log_out:
            self.log.configure(state=tk.NORMAL)
            self.log.delete("1.0", tk.END)
            self.log.insert(tk.END, log_out + "\n")
            self.log.see(tk.END)
            self.log.configure(state=tk.DISABLED)

    def restart_action(self) -> str:
        if not RESTART_SH.is_file():
            raise RuntimeError(f"找不到 {RESTART_SH}，请先运行 ./install.sh")
        code, out = _run(["bash", str(RESTART_SH), "restart"], timeout=90)
        self.refresh_status()
        if code == 0:
            return "✓ Gateway 已重启 — MCP / config.yaml 变更已生效"
        raise RuntimeError(out or "重启失败")

    def fix_action(self) -> str:
        if not RESTART_SH.is_file():
            raise RuntimeError(f"找不到 {RESTART_SH}，请先运行 ./install.sh")
        code, out = _run(["bash", str(RESTART_SH), "console"], timeout=240)
        self.refresh_status()
        if code == 0:
            if discord_live_ok():
                return "✓ 修复完成，Discord 可对话 — 去 Discord 发消息试试"
            return "Gateway 已重启，Discord 显示已连接"
        if code == 2:
            return (
                "Gateway 已启动，但 Discord 连不上（网络/代理）\n"
                "请确认代理在跑，或等网络稳定后再点一次修复（勿连点）"
            )
        raise RuntimeError(out or "修复失败")

    def stop_action(self) -> str:
        _run(["systemctl", "--user", "kill", "-s", "SIGKILL", "hermes-gateway.service"], timeout=10)
        return "Hermes 已停止"

    def restart_gateway(self) -> None:
        self.root.after(0, lambda: self._append_log(">>> 重启 Gateway（等同 hermes gateway restart）…"))
        self._worker("重启 Gateway", self.restart_action, busy_hint="正在重启 Gateway，约 10 秒…")

    def fix_and_reconnect(self) -> None:
        self.root.after(0, lambda: self._append_log(">>> 开始修复并重连（请勿重复点击，约 30–120 秒）…"))
        self._worker("修复并重连", self.fix_action, busy_hint="正在修复并重连，请勿重复点击…")

    def stop_hermes(self) -> None:
        self._worker("停止 Hermes", self.stop_action, busy_hint="正在停止…")

    def run(self) -> None:
        self.root.mainloop()


def main() -> int:
    os.environ.setdefault("HERMES_HOME", str(HERMES_HOME))
    LauncherApp().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
