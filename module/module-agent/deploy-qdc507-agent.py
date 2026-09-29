#!/usr/bin/env python3
"""通过 DJOneHub 自带 libusb 将 iPad 代理安全部署到已验证的 QDC507。"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import re
import secrets
import shlex
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


MODULE_DIRECTORY = Path(__file__).resolve().parent
PACKAGE_DIRECTORY = MODULE_DIRECTORY.parent
WORKSPACE_DIRECTORY = MODULE_DIRECTORY.parent.parent
# 源码树的探针在仓库父目录，分享包的探针在包根目录；两种入口都必须解析到同一份文件。
PACKAGE_PROBE_PATH = PACKAGE_DIRECTORY / "qdc507-adb-probe.py"
PROBE_PATH = (
    PACKAGE_PROBE_PATH
    if PACKAGE_PROBE_PATH.is_file()
    else WORKSPACE_DIRECTORY / "module/qdc507-adb-probe.py"
)
AGENT_PATH = MODULE_DIRECTORY / "qdc507-agent"
DATA11_BRIDGE_PATH = MODULE_DIRECTORY.parent / "kernel-bridge/qdc507_data11_bridge.ko"
# 可通过环境变量覆盖语音运行时目录；默认值不再绑定某个开发者用户名。
PACKAGED_VOICE_SOURCE = MODULE_DIRECTORY / "voice-runtime"
DEFAULT_VOICE_SOURCE = (
    PACKAGED_VOICE_SOURCE
    if PACKAGED_VOICE_SOURCE.is_dir()
    else Path.home() / "Library/Application Support/DJOneHub/voice-runtime/mavo-0443dfd"
)
VOICE_SOURCE = Path(os.environ.get("DJONEHUB_VOICE_RUNTIME", str(DEFAULT_VOICE_SOURCE)))
VOICE_SOURCES = {
    # 内核驱动沿用已实机验证的 MaVo 文件，网络 PCM helper 使用本项目的新产物。
    "qdc507_aprv3.ko": VOICE_SOURCE / "qdc507_aprv3.ko",
    "qdc507_voice.ko": VOICE_SOURCE / "qdc507_voice.ko",
    "mavo-pcm-bridge.armv7": MODULE_DIRECTORY
    / "pcm-bridge/mavo-pcm-bridge.armv7",
}

EXPECTED_FILES = {
    "qdc507_aprv3.ko": "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a",
    "qdc507_voice.ko": "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c",
    "mavo-pcm-bridge.armv7": "13d034205664071db51120f349af7f785df58e269eeb07f531af5be18d0af228",
}

INIT_SCRIPT = r'''#!/bin/sh
# DJOneHub 双模式启动器：Mac 模式保留原厂 USB，移动模式才启用 DATA11 Agent。
AGENT=/data/djonehub/bin/qdc507-agent
RECOVERY_AGENT=/data/djonehub/bin/qdc507-agent.recovery
DATA_ROOT=/data/djonehub
BRIDGE=/data/djonehub/kernel/qdc507_data11_bridge.ko
NODE=/dev/djonehub_data11
PIDFILE=/run/djonehub-agent.pid
SUPERVISOR_PIDFILE=/run/djonehub-supervisor.pid
STOP_MARKER=/run/djonehub-agent.stop
USB_REBIND_STAMP=/run/djonehub-usb-rebind.uptime
LOGFILE=/data/djonehub/log/agent.log
GADGET=/sys/devices/virtual/android_usb/android0
ENABLE=$GADGET/enable
FUNCTIONS=$GADGET/functions
TRANSPORTS=$GADGET/f_serial/transports
SERIAL_CONNECTED=$GADGET/f_serial/is_connected_flag
STARTUP_LOG=/data/djonehub/log/startup.log
UPDATE_MARKER=/data/djonehub/update-pending
MAC_MODE_MARKER=/data/djonehub/usb-mode-mac

log_startup() {
    mkdir -p /data/djonehub/log
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$STARTUP_LOG"
}

log_usb_state() {
    phase=$1
    carrier=$(cat /sys/class/net/ecm0/carrier 2>/dev/null || echo missing)
    operstate=$(cat /sys/class/net/ecm0/operstate 2>/dev/null || echo missing)
    functions=$(cat "$FUNCTIONS" 2>/dev/null || echo missing)
    enabled=$(cat "$ENABLE" 2>/dev/null || echo missing)
    agent_pid=$(sed -n '1s/ .*//p' "$PIDFILE" 2>/dev/null || true)
    factory_pid=$(pidof ql_manager_server 2>/dev/null | tr ' ' ',' || true)
    test -n "$agent_pid" || agent_pid=missing
    test -n "$factory_pid" || factory_pid=missing
    log_startup "usb-state phase=$phase carrier=$carrier operstate=$operstate functions=$functions enabled=$enabled agent_pid=$agent_pid ql_manager_server_pid=$factory_pid"
}

owned_agent() {
    test -s "$PIDFILE" || return 1
    read pid expected_start < "$PIDFILE" || return 1
    case "$pid:$expected_start" in :*|*:|*[!0-9:]*) return 1;; esac
    test "$(cut -d ' ' -f 22 "/proc/$pid/stat" 2>/dev/null)" = "$expected_start" || return 1
    test "$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '1p')" = "$AGENT"
}

owned_supervisor() {
    test -s "$SUPERVISOR_PIDFILE" || return 1
    read pid expected_start < "$SUPERVISOR_PIDFILE" || return 1
    case "$pid:$expected_start" in :*|*:|*[!0-9:]*) return 1;; esac
    test "$(cut -d ' ' -f 22 "/proc/$pid/stat" 2>/dev/null)" = "$expected_start" || return 1
    argv2=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '2p')
    argv3=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '3p')
    argv4=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '4p')
    case "$argv2:$argv3:$argv4" in
        /etc/init.d/djonehub_agent:supervise:|/bin/sh:/etc/init.d/djonehub_agent:supervise) return 0;;
        *) return 1;;
    esac
}

wait_agent_health() {
    n=0
    while test "$n" -lt 30; do
        if owned_agent && busybox wget -q -T 3 -O - http://127.0.0.1:7575/api/health 2>/dev/null >/dev/null; then
            return 0
        fi
        sleep 0.5
        n=$((n+1))
    done
    return 1
}

confirm_pending_update() {
    test -s "$UPDATE_MARKER" || return 0
    backup=$(sed -n '1p' "$UPDATE_MARKER")
    case "$backup" in
        "$DATA_ROOT"/backup/app-update-*) ;;
        *) log_startup "update-confirmation-invalid-backup backup=$backup"; return 1;;
    esac
    rm -f "$UPDATE_MARKER" || return 1
    if ! rm -rf "$backup"; then
        log_startup "update-confirmed-backup-cleanup-warning backup=$backup"
        return 0
    fi
    log_startup "update-confirmed backup=$backup"
}

stop_owned_agent() {
    owned_agent || return 0
    read pid expected_start < "$PIDFILE"
    kill -TERM "$pid" 2>/dev/null || true
    n=0
    while owned_agent && test "$n" -lt 50; do
        sleep 0.1
        n=$((n+1))
    done
    owned_agent && kill -KILL "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
}

restore_agent_binary() {
    test -x "$AGENT" && return 0
    test -x "$RECOVERY_AGENT" || return 1
    rm -f "$AGENT"
    ln "$RECOVERY_AGENT" "$AGENT" || return 1
    chmod 755 "$AGENT"
    log_startup agent-binary-restored-from-recovery-link
}

rebind_usb_if_safe() {
    calls=$(busybox wget -q -T 3 -O - http://127.0.0.1:7575/api/calls/status 2>/dev/null) || return 1
    printf '%s' "$calls" | grep -q '"active":null' || return 1
    current=$(cat "$FUNCTIONS" 2>/dev/null || true)
    case ",$current," in
        *,ecm,*) ;;
        *) return 1;;
    esac
    case ",$current," in
        *,serial,*|*,audio,*) return 1;;
    esac
    now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    last=$(cat "$USB_REBIND_STAMP" 2>/dev/null || echo 0)
    case "$now:$last" in :*|*:|*[!0-9:]*) return 1;; esac
    test $((now-last)) -ge 300 || return 1
    printf '%s\n' "$now" > "$USB_REBIND_STAMP"
    log_usb_state rebind-before
    log_startup "USB software rebind started functions=$current"
    echo 0 > "$ENABLE" || return 1
    sleep 1
    echo 1 > "$ENABLE" || return 1
    log_startup "USB software rebind completed functions=$(cat "$FUNCTIONS" 2>/dev/null)"
    log_usb_state rebind-after
}

supervise_agent() {
    child=
    stop_requested() {
        test -e "$STOP_MARKER"
    }
    terminate_child() {
        test -n "$child" || return 0
        kill -TERM "$child" 2>/dev/null || true
    }
    trap 'touch "$STOP_MARKER"; terminate_child' TERM INT HUP
    rm -f "$STOP_MARKER" "$PIDFILE"
    restart_delay=1
    while ! stop_requested; do
        if ! restore_agent_binary; then
            log_startup "supervisor-agent-binary-missing restart_in=${restart_delay}s"
            sleep "$restart_delay"
            test "$restart_delay" -ge 30 || restart_delay=$((restart_delay*2))
            test "$restart_delay" -le 30 || restart_delay=30
            continue
        fi
        "$AGENT" &
        child=$!
        starttime=$(cut -d ' ' -f 22 "/proc/$child/stat" 2>/dev/null)
        case "$child:$starttime" in
            :*|*:|*[!0-9:]*)
                log_startup invalid-supervised-agent-pid
                sleep "$restart_delay"
                continue
                ;;
        esac
        printf '%s %s\n' "$child" "$starttime" > "$PIDFILE"
        log_startup "supervisor-agent-start pid=$child"
        log_usb_state agent-start
        unhealthy=0
        carrier_down=0
        while kill -0 "$child" 2>/dev/null && ! stop_requested; do
            sleep 10
            kill -0 "$child" 2>/dev/null || break
            if busybox wget -q -T 3 -O - http://127.0.0.1:7575/api/health 2>/dev/null >/dev/null; then
                unhealthy=0
                if test "$(cat /sys/class/net/ecm0/carrier 2>/dev/null)" = 0; then
                    carrier_down=$((carrier_down+1))
                    if test "$carrier_down" -eq 1; then
                        log_usb_state carrier-down
                    fi
                    if test "$carrier_down" -ge 6; then
                        rebind_usb_if_safe || true
                        carrier_down=0
                    fi
                else
                    if test "$carrier_down" -gt 0; then
                        log_usb_state carrier-recovered
                    fi
                    carrier_down=0
                fi
            else
                unhealthy=$((unhealthy+1))
                if test "$unhealthy" -ge 3; then
                    log_startup "supervisor-health-timeout pid=$child failures=$unhealthy"
                    log_usb_state agent-health-timeout
                    terminate_child
                    break
                fi
            fi
        done
        wait "$child" 2>/dev/null
        child_result=$?
        rm -f "$PIDFILE"
        child=
        stop_requested && break
        log_startup "supervisor-agent-exit code=$child_result restart_in=${restart_delay}s"
        log_usb_state agent-exit
        sleep "$restart_delay"
        test "$restart_delay" -ge 30 || restart_delay=$((restart_delay*2))
        test "$restart_delay" -le 30 || restart_delay=30
    done
    rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE"
    log_startup supervisor-stop
}

rollback_pending_update() {
    test -s "$UPDATE_MARKER" || return 1
    backup=$(sed -n '1p' "$UPDATE_MARKER")
    case "$backup" in /data/djonehub/backup/app-update-*) ;; *) return 1;; esac
    test -d "$backup" || return 1
    log_startup "update-rollback-start backup=$backup"
    if owned_agent; then
        read pid expected_start < "$PIDFILE"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PIDFILE" "$UPDATE_MARKER"
    for mapping in \
        qdc507-agent:/data/djonehub/bin/qdc507-agent \
        qdc507_data11_bridge.ko:/data/djonehub/kernel/qdc507_data11_bridge.ko \
        qdc507_aprv3.ko:/data/djonehub/voice-runtime/qdc507_aprv3.ko \
        qdc507_voice.ko:/data/djonehub/voice-runtime/qdc507_voice.ko \
        mavo-pcm-bridge.armv7:/data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; do
        name=${mapping%%:*}
        target=${mapping#*:}
        test -f "$backup/$name" || return 1
        mv "$target" "$target.update-failed" 2>/dev/null || true
        mv "$backup/$name" "$target" || return 1
    done
    chmod 755 "$AGENT" /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7
    chmod 644 "$BRIDGE" /data/djonehub/voice-runtime/*.ko
    if owned_supervisor; then
        wait_agent_health || return 1
    else
        nohup "$AGENT" </dev/null >>"$LOGFILE" 2>&1 &
        pid=$!
        starttime=$(cut -d ' ' -f 22 "/proc/$pid/stat" 2>/dev/null)
        case "$pid:$starttime" in :*|*:|*[!0-9:]*) return 1;; esac
        printf '%s %s\n' "$pid" "$starttime" > "$PIDFILE"
        wait_agent_health || return 1
    fi
    log_startup "update-rollback-complete backup=$backup"
}

wait_usb_profile() {
    n=0
    while test "$n" -lt 100; do
        current=$(cat "$FUNCTIONS" 2>/dev/null || true)
        case ",$current," in
            *,ecm,*) return 0 ;;
        esac
        sleep 0.2
        n=$((n+1))
    done
    return 1
}

wait_mobile_profile() {
    n=0
    while test "$n" -lt 25; do
        current=$(cat "$FUNCTIONS" 2>/dev/null || true)
        case ",$current," in
            *,ecm,*)
                case ",$current," in
                    *,audio,*) ;;
                    *) return 0 ;;
                esac
                ;;
        esac
        sleep 0.2
        n=$((n+1))
    done
    # 该固件在部分 iPhone 上也会错误地保持 audio 描述符与
    # is_connected_flag=1，无法用串口标志可靠区分 macOS/iOS。
    # ECM 已就绪但组合未自动收敛时，默认进入移动模式；Mac 完整模式由用户显式切换。
    return 0
}

is_mobile_profile() {
    current=$(cat "$FUNCTIONS" 2>/dev/null || true)
    case ",$current," in
        *,audio,*) return 1 ;;
        *) return 0 ;;
    esac
}

is_explicit_mac_profile() {
    test -f "$MAC_MODE_MARKER"
}

load_data11_bridge() {
    grep -q '^qdc507_data11_bridge ' /proc/modules 2>/dev/null || insmod "$BRIDGE"
    minor=$(awk '$2 == "djonehub_data11" { print $1 }' /proc/misc)
    test -n "$minor" || return 1
    test -c "$NODE" || {
        rm -f "$NODE"
        mknod "$NODE" c 10 "$minor"
    }
    chmod 600 "$NODE"
}

wait_factory_service() {
    n=0
    while test "$n" -lt 450; do
        factory_pid=$(pidof ql_manager_server 2>/dev/null || true)
        if test -n "$factory_pid"; then
            printf '%s\n' "$factory_pid"
            return 0
        fi
        sleep 0.2
        n=$((n+1))
    done
    return 1
}

activate_mobile_functions() {
    original=$(cat "$FUNCTIONS")
    detached=$(echo "$original" | sed 's/^serial,//; s/,serial,/,/; s/,serial$//; s/^serial$//; s/^audio,//; s/,audio,/,/; s/,audio$//; s/^audio$//')
    test "$detached" != "$original" || return 0
    echo 0 >"$ENABLE"
    sleep 1
    # 移动模式同时移除 serial 与 audio；保留 ECM/ADB，且不触碰原厂 DATA1 服务。
    echo tty >"$TRANSPORTS"
    echo "$detached" >"$FUNCTIONS"
    echo 1 >"$ENABLE"
    sleep 2
}

case "${1:-}" in
supervise)
    supervise_agent
    ;;
start)
    if owned_supervisor && wait_agent_health; then
        exit 0
    fi
    touch "$STOP_MARKER"
    stop_owned_agent
    if owned_supervisor; then
        read supervisor_pid supervisor_start < "$SUPERVISOR_PIDFILE"
        kill -TERM "$supervisor_pid" 2>/dev/null || true
        n=0
        while owned_supervisor && test "$n" -lt 50; do sleep 0.1; n=$((n+1)); done
    fi
    rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$STOP_MARKER"
    restore_agent_binary || { log_startup missing-runtime; exit 66; }
    test -f "$BRIDGE" || { log_startup missing-runtime; exit 66; }
    wait_usb_profile || { log_startup no-ecm-profile; exit 67; }
    # 用户显式选择 Mac 模式时保留一次完整 USB 组合。标记在消费后立即删除，
    # 下次重新供电接入 iPhone 时仍会按移动模式启动 Agent。
    if is_explicit_mac_profile; then
        rm -f "$MAC_MODE_MARKER"
        if ! is_mobile_profile; then
            log_startup "mac-pass-through functions=$(cat "$FUNCTIONS") explicit=1"
            exit 0
        fi
    fi
    # 优先等待固件切换到无 audio 的移动组合；若固件保留 audio，则短暂等待后默认进入移动模式。
    if ! is_mobile_profile && ! wait_mobile_profile; then
        log_startup "mac-pass-through functions=$(cat "$FUNCTIONS") serial_connected=$(cat "$SERIAL_CONNECTED" 2>/dev/null)"
        exit 0
    fi
    log_startup "mobile-start functions=$(cat "$FUNCTIONS") serial_connected=$(cat "$SERIAL_CONNECTED" 2>/dev/null)"
    before=$(wait_factory_service) || { log_startup missing-factory-service-after-wait; exit 68; }
    log_startup "factory-service-ready pid=$before functions=$(cat "$FUNCTIONS")"
    activate_mobile_functions || { log_startup activate-mobile-functions-failed; exit 69; }
    test "$(pidof ql_manager_server)" = "$before" || { log_startup factory-service-changed; exit 70; }
    load_data11_bridge || { log_startup load-data11-failed; exit 71; }
    mkdir -p /data/djonehub/log
    setsid /bin/sh /etc/init.d/djonehub_agent supervise </dev/null >>"$LOGFILE" 2>&1 &
    supervisor_pid=$!
    supervisor_start=$(cut -d ' ' -f 22 "/proc/$supervisor_pid/stat" 2>/dev/null)
    case "$supervisor_pid:$supervisor_start" in :*|*:|*[!0-9:]*) log_startup invalid-supervisor-pid; exit 72;; esac
    printf '%s %s\n' "$supervisor_pid" "$supervisor_start" > "$SUPERVISOR_PIDFILE"
    if ! wait_agent_health; then
        rollback_pending_update && exit 0
        log_startup supervised-agent-unhealthy
        exit 73
    fi
    # 每次健康启动后都刷新恢复链接。更新器会用 rename 替换 AGENT；若只在文件缺失时
    # 创建链接，RECOVERY_AGENT 会继续引用旧 inode，并长期多占约 7 MB。
    rm -f "$RECOVERY_AGENT.next"
    if ln "$AGENT" "$RECOVERY_AGENT.next"; then
        # BusyBox mv 在源和目标已经是同一 inode 时会保留 .next；先移除旧名称，
        # 再把临时硬链接原子落到标准路径。
        rm -f "$RECOVERY_AGENT"
        mv -f "$RECOVERY_AGENT.next" "$RECOVERY_AGENT"
    else
        log_startup recovery-link-refresh-failed
    fi
    confirm_pending_update || { log_startup update-confirmation-failed; exit 74; }
    read pid expected_start < "$PIDFILE"
    log_startup "mobile-agent-ready pid=$pid supervisor_pid=$supervisor_pid factory_pid=$before"
    ;;
stop)
    touch "$STOP_MARKER"
    stop_owned_agent
    if owned_supervisor; then
        read supervisor_pid supervisor_start < "$SUPERVISOR_PIDFILE"
        kill -TERM "$supervisor_pid" 2>/dev/null || true
        n=0
        while owned_supervisor && test "$n" -lt 50; do sleep 0.1; n=$((n+1)); done
        owned_supervisor && kill -KILL "$supervisor_pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$STOP_MARKER"
    ;;
restart)
    "$0" stop && "$0" start
    ;;
status)
    if owned_supervisor && owned_agent; then
        echo mobile-agent
        exit 0
    fi
    if wait_usb_profile && ! is_mobile_profile; then
        echo mac-pass-through
        exit 0
    fi
    exit 1
    ;;
*)
    echo "usage: $0 {start|stop|restart|status}" >&2
    exit 64
    ;;
esac
'''


def load_probe_module():
    """加载现有且已实机验证的 USB ADB 传输，不复制另一套底层实现。"""
    spec = importlib.util.spec_from_file_location("qdc507_adb_probe", PROBE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载 QDC507 ADB 传输")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DeployTransport:
    """在只读探针之上补充 ADB sync push 与带退出状态的 shell。"""

    def __init__(self, probe_module) -> None:
        self._probe = probe_module
        self._transport = probe_module.UsbAdbTransport()
        self._next_local_id = 2

    def open(self) -> None:
        self._transport.open()
        self._transport.connect()

    def close(self) -> None:
        self._transport.close()

    def shell(self, command: str, timeout_seconds: int = 20) -> str:
        """执行命令并用随机标记严格取回退出状态。"""
        token = secrets.token_hex(12)
        marker = f"__DJONEHUB_STATUS_{token}_"
        wrapped = (
            f"{{ {command}; }}; code=$?; "
            f"printf '\n{marker}%u__\n' \"$code\""
        )
        old_timeout = self._probe.USB_TIMEOUT_MS
        self._probe.USB_TIMEOUT_MS = max(old_timeout, timeout_seconds * 1000)
        try:
            output = self._transport.run_shell(wrapped).decode("utf-8", errors="replace")
        finally:
            self._probe.USB_TIMEOUT_MS = old_timeout
        position = output.rfind(marker)
        if position < 0:
            raise RuntimeError(f"模块 shell 未返回退出状态：{output[-500:]}")
        status_text = output[position + len(marker) :].split("__", 1)[0]
        status = int(status_text)
        clean = output[:position].rstrip()
        if status != 0:
            raise RuntimeError(f"模块命令失败（{status}）：{clean[-5000:]}")
        return clean

    def _open_service(self, service: str) -> tuple[int, int]:
        local_id = self._next_local_id
        self._next_local_id += 1
        self._transport.send_message(
            self._probe.ADB_OPEN, local_id, 0, service.encode("utf-8") + b"\x00"
        )
        while True:
            message = self._transport.read_message()
            if message.command == self._probe.ADB_OKAY and message.arg1 == local_id:
                return local_id, message.arg0
            if message.command == self._probe.ADB_CLSE and message.arg1 == local_id:
                raise RuntimeError(f"模块拒绝 ADB 服务：{service}")
            self._ack_or_close_unexpected(message)

    def _ack_or_close_unexpected(self, message) -> None:
        if message.command == self._probe.ADB_WRTE:
            self._transport.send_message(
                self._probe.ADB_OKAY, message.arg1, message.arg0
            )
        elif message.command == self._probe.ADB_CLSE and message.arg0 and message.arg1:
            self._transport.send_message(
                self._probe.ADB_CLSE, message.arg1, message.arg0
            )

    def _write_stream(self, local_id: int, remote_id: int, payload: bytes) -> None:
        if len(payload) > 4096:
            raise RuntimeError("ADB 数据块超过模块协商上限")
        self._transport.send_message(
            self._probe.ADB_WRTE, local_id, remote_id, payload
        )
        while True:
            message = self._transport.read_message()
            if (
                message.command == self._probe.ADB_OKAY
                and message.arg0 == remote_id
                and message.arg1 == local_id
            ):
                return
            if message.command == self._probe.ADB_CLSE and message.arg1 == local_id:
                raise RuntimeError("ADB sync 流被模块提前关闭")
            self._ack_or_close_unexpected(message)

    def _close_stream(self, local_id: int, remote_id: int) -> None:
        self._transport.send_message(
            self._probe.ADB_CLSE, local_id, remote_id
        )
        while True:
            message = self._transport.read_message()
            if message.command == self._probe.ADB_CLSE and message.arg1 == local_id:
                if message.arg0:
                    self._transport.send_message(
                        self._probe.ADB_CLSE, local_id, remote_id
                    )
                return
            self._ack_or_close_unexpected(message)

    def push(self, data: bytes, remote_path: str, mode: int) -> None:
        """使用标准 ADB sync SEND/DATA/DONE 协议原子传输到临时路径。"""
        if not remote_path.startswith("/") or "," in remote_path or "\x00" in remote_path:
            raise ValueError("ADB push 目标路径无效")
        local_id, remote_id = self._open_service("sync:")
        try:
            name = f"{remote_path},{mode}".encode("utf-8")
            self._write_stream(local_id, remote_id, b"SEND" + struct.pack("<I", len(name)) + name)
            for offset in range(0, len(data), 4088):
                chunk = data[offset : offset + 4088]
                packet = b"DATA" + struct.pack("<I", len(chunk)) + chunk
                self._write_stream(local_id, remote_id, packet)
            self._write_stream(
                local_id,
                remote_id,
                b"DONE" + struct.pack("<I", int(time.time())),
            )

            response = bytearray()
            while len(response) < 4:
                message = self._transport.read_message()
                if message.command == self._probe.ADB_WRTE:
                    response.extend(message.payload)
                    self._transport.send_message(
                        self._probe.ADB_OKAY, local_id, remote_id
                    )
                elif message.command == self._probe.ADB_CLSE:
                    raise RuntimeError("ADB sync 未返回结果")
            if response[:4] == b"FAIL":
                while len(response) < 8:
                    message = self._transport.read_message()
                    if message.command == self._probe.ADB_WRTE:
                        response.extend(message.payload)
                        self._transport.send_message(
                            self._probe.ADB_OKAY, local_id, remote_id
                        )
                length = struct.unpack("<I", response[4:8])[0]
                while len(response) < 8 + length:
                    message = self._transport.read_message()
                    if message.command == self._probe.ADB_WRTE:
                        response.extend(message.payload)
                        self._transport.send_message(
                            self._probe.ADB_OKAY, local_id, remote_id
                        )
                raise RuntimeError(response[8 : 8 + length].decode(errors="replace"))
            if response[:4] != b"OKAY":
                raise RuntimeError(f"ADB sync 返回未知状态：{bytes(response[:8])!r}")
        finally:
            self._close_stream(local_id, remote_id)

    def pull(self, remote_path: str) -> bytes:
        """使用标准 ADB sync RECV/DATA/DONE 协议只读拉取模块文件。"""
        if not remote_path.startswith("/") or "\x00" in remote_path:
            raise ValueError("ADB pull 源路径无效")
        local_id, remote_id = self._open_service("sync:")
        try:
            encoded_path = remote_path.encode("utf-8")
            request = b"RECV" + struct.pack("<I", len(encoded_path)) + encoded_path
            self._write_stream(local_id, remote_id, request)

            stream = bytearray()
            result = bytearray()
            while True:
                message = self._transport.read_message()
                if message.command == self._probe.ADB_WRTE:
                    stream.extend(message.payload)
                    self._transport.send_message(
                        self._probe.ADB_OKAY, local_id, remote_id
                    )
                    while len(stream) >= 8:
                        packet_type = bytes(stream[:4])
                        packet_length = struct.unpack("<I", stream[4:8])[0]
                        if packet_type == b"DONE":
                            del stream[:8]
                            return bytes(result)
                        if len(stream) < 8 + packet_length:
                            break
                        payload = bytes(stream[8 : 8 + packet_length])
                        del stream[: 8 + packet_length]
                        if packet_type == b"DATA":
                            result.extend(payload)
                        elif packet_type == b"FAIL":
                            raise RuntimeError(payload.decode(errors="replace"))
                        else:
                            raise RuntimeError(f"ADB sync 返回未知状态：{packet_type!r}")
                elif message.command == self._probe.ADB_CLSE:
                    raise RuntimeError("ADB sync pull 未返回 DONE")
                else:
                    self._ack_or_close_unexpected(message)
        finally:
            self._close_stream(local_id, remote_id)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class DeploymentPlan:
    stage_names: tuple[str, ...]
    backup_existing_agent: bool
    required_bytes: int


def make_deployment_plan(
    *,
    expected_hashes: Mapping[str, str],
    installed_hashes: Mapping[str, str],
    file_sizes: Mapping[str, int],
    available_bytes: int,
) -> DeploymentPlan:
    """只暂存发生变化的文件，并为已安装的旧 Agent 保留 Mac 端回滚副本。"""
    stage_names = tuple(
        name
        for name, expected_hash in expected_hashes.items()
        if installed_hashes.get(name) != expected_hash
    )
    required_bytes = sum(file_sizes[name] for name in stage_names) + 128 * 1024
    if required_bytes > available_bytes:
        raise RuntimeError(
            f"/data 剩余空间不足：需要至少 {required_bytes} 字节，"
            f"实际 {available_bytes} 字节"
        )
    return DeploymentPlan(
        stage_names=stage_names,
        backup_existing_agent=(
            "agent" in installed_hashes and "agent" in stage_names
        ),
        required_bytes=required_bytes,
    )


def verify_local_files() -> dict[Path, str]:
    """部署前固定目标及摘要，避免路径替换或传输错包。"""
    if not AGENT_PATH.is_file():
        raise RuntimeError(f"缺少代理程序：{AGENT_PATH}")
    if not DATA11_BRIDGE_PATH.is_file():
        raise RuntimeError(f"缺少 DATA11 桥：{DATA11_BRIDGE_PATH}")
    files = {
        AGENT_PATH: sha256(AGENT_PATH),
        DATA11_BRIDGE_PATH: sha256(DATA11_BRIDGE_PATH),
    }
    for name, expected in EXPECTED_FILES.items():
        path = VOICE_SOURCES[name]
        if not path.is_file() or sha256(path) != expected:
            raise RuntimeError(f"语音运行时校验失败：{path}")
        files[path] = expected
    return files


def verify_runtime_probe(preflight: str, helper_hash: str) -> None:
    """同时校验启动能力和 Agent 内嵌的 helper 白名单，拒绝错配部署。"""
    if "启动探针通过: runtime" not in preflight:
        raise RuntimeError(f"新 Agent 启动兼容检查失败：{preflight}")
    marker = f"__VOICE_HELPER_SHA256__{helper_hash}"
    if marker not in preflight:
        raise RuntimeError(
            "新 Agent 内嵌的语音 helper SHA-256 与待部署文件不一致："
            f"{preflight}"
        )


def deploy() -> None:
    files = verify_local_files()
    helper_hash = files[VOICE_SOURCES["mavo-pcm-bridge.armv7"]]
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    committed = False
    factory_pid = ""
    recovery_agent_data: bytes | None = None
    preexisting_paths: set[str] = set()
    deployment_entries: list[tuple[str, Path, str, str, int]] = []
    plan: DeploymentPlan | None = None
    try:
        identity = transport.shell("id -u; uname -m; uname -r; df -k /data")
        normalized_identity = identity.replace("\r", "")
        if not normalized_identity.startswith("0\narmv7l\n3.18.44"):
            raise RuntimeError(f"模块身份不符合已验证目标：\n{identity}")
        profile = transport.shell(
            "vendor=$(cat /sys/devices/virtual/android_usb/android0/idVendor); "
            "product=$(cat /sys/devices/virtual/android_usb/android0/idProduct); "
            "functions=$(cat /sys/devices/virtual/android_usb/android0/functions); "
            "test \"$vendor:$product\" = '2c7c:0125'; "
            "case ,$functions, in *,audio,*) ;; *) exit 41;; esac; "
            "case ,$functions, in *,serial,*) ;; *) exit 42;; esac; "
            "case ,$functions, in *,ecm,*) ;; *) exit 43;; esac; "
            "printf '%s:%s %s\\n' \"$vendor\" \"$product\" \"$functions\""
        )
        factory_pid = transport.shell("pidof ql_manager_server").strip()
        if not re.fullmatch(r"[0-9]+", factory_pid):
            raise RuntimeError(f"原厂 ql_manager_server 状态异常：{factory_pid!r}")
        hooks = transport.shell(
            "test ! -e /etc/init.d/djonehub_agent; "
            "test ! -e /etc/rc5.d/S99djonehub_agent; "
            "test ! -e /etc/rc5.d/S99zz_djonehub_agent; "
            "echo clean"
        )
        if hooks.strip() != "clean":
            raise RuntimeError("模块已有未知的 DJOneHub 启动钩子，拒绝覆盖")
        print(f"已确认 Mac 完整模式：{profile}；原厂服务 PID={factory_pid}", flush=True)
        call_check = transport.shell(
            "(sleep 1; printf 'block_check_condition call_state NONE\\n'; "
            "sleep 1; printf 'quit\\n') | timeout -t 8 "
            "/usr/bin/qmi_simple_ril_test 2>&1 | tail -n 40",
            timeout_seconds=15,
        )
        if "TRUE" not in call_check:
            raise RuntimeError("模块可能正在通话，拒绝部署")

        deployment_entries = [
            (
                "agent",
                AGENT_PATH,
                "/data/local/tmp/qdc507-agent.new",
                "/data/djonehub/bin/qdc507-agent",
                0o755,
            ),
            (
                "bridge",
                DATA11_BRIDGE_PATH,
                "/data/local/tmp/qdc507_data11_bridge.ko.new",
                "/data/djonehub/kernel/qdc507_data11_bridge.ko",
                0o644,
            ),
        ]
        for name in EXPECTED_FILES:
            deployment_entries.append(
                (
                    name,
                    VOICE_SOURCES[name],
                    f"/data/local/tmp/{name}.new",
                    f"/data/djonehub/voice-runtime/{name}",
                    0o755 if name.endswith("armv7") else 0o644,
                )
            )

        expected_hashes = {
            name: files[local_path]
            for name, local_path, _, _, _ in deployment_entries
        }
        installed_hashes: dict[str, str] = {}
        for name, _, _, final_path, _ in deployment_entries:
            installed_hash = transport.shell(
                f"test ! -f {shlex.quote(final_path)} || "
                f"busybox sha256sum {shlex.quote(final_path)} | awk '{{print $1}}'"
            ).strip()
            if installed_hash:
                installed_hashes[name] = installed_hash
                preexisting_paths.add(final_path)
        available_bytes = int(
            transport.shell("df -Pk /data | awk 'NR==2 {print $4}'").strip()
        ) * 1024
        plan = make_deployment_plan(
            expected_hashes=expected_hashes,
            installed_hashes=installed_hashes,
            file_sizes={
                name: local_path.stat().st_size
                for name, local_path, _, _, _ in deployment_entries
            },
            available_bytes=available_bytes,
        )
        if plan.backup_existing_agent:
            recovery_agent_data = transport.pull("/data/djonehub/bin/qdc507-agent")
            if (
                len(recovery_agent_data) <= 5_000_000
                or hashlib.sha256(recovery_agent_data).hexdigest()
                != installed_hashes["agent"]
            ):
                raise RuntimeError("旧 Agent 拉取回滚副本后校验失败")
            print("旧 Agent 已安全备份到 Mac 内存", flush=True)

        transport.shell("mkdir -p /data/local/tmp /data/djonehub/backup")
        for name, local_path, remote_path, _, mode in deployment_entries:
            expected = files[local_path]
            if name not in plan.stage_names:
                print(f"复用已安装且校验通过的 {local_path.name}", flush=True)
                continue
            actual = transport.shell(
                f"test ! -f '{remote_path}' || busybox sha256sum '{remote_path}' | awk '{{print $1}}'"
            )
            if actual.strip() != expected:
                print(f"推送 {local_path.name} ...", flush=True)
                transport.push(local_path.read_bytes(), remote_path, mode)
                actual = transport.shell(f"busybox sha256sum '{remote_path}' | awk '{{print $1}}'")
            else:
                print(f"复用已校验的 {local_path.name}", flush=True)
            if actual.strip() != expected:
                raise RuntimeError(f"模块端 SHA-256 不匹配：{local_path.name}")

        # 提交前必须在原厂服务仍运行时通过纯启动探针，阻止不兼容工具链产物写入正式路径。
        preflight_agent = (
            "/data/local/tmp/qdc507-agent.new"
            if "agent" in plan.stage_names
            else "/data/djonehub/bin/qdc507-agent"
        )
        preflight = transport.shell(f"{preflight_agent} --startup-probe runtime 2>&1")
        verify_runtime_probe(preflight, helper_hash)
        if transport.shell("pidof ql_manager_server").strip() != factory_pid:
            raise RuntimeError("提交前原厂 ql_manager_server PID 发生变化")

        transport.push(INIT_SCRIPT.encode("utf-8"), "/data/local/tmp/djonehub_agent.new", 0o755)
        move_commands = "".join(
            f"mv {shlex.quote(remote_path)} {shlex.quote(final_path)}; "
            for name, _, remote_path, final_path, _ in deployment_entries
            if name in plan.stage_names
        )
        # 根分区只在提交 init 对象期间可写；trap 保证所有退出路径恢复只读。
        committed = True
        transport.shell(
            "set -e; "
            "restore_ro() { mount -o remount,ro / >/dev/null 2>&1 || true; }; "
            "trap restore_ro 0 1 2 3 15; "
            "mkdir -p /data/djonehub/bin /data/djonehub/kernel /data/djonehub/voice-runtime /data/djonehub/log; "
            # 所有 .new 都在同一 UBI 卷，rename 覆盖不会再复制一份大文件。
            f"{move_commands}"
            "chmod 755 /data/djonehub/bin/qdc507-agent /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; "
            "chmod 644 /data/djonehub/kernel/qdc507_data11_bridge.ko /data/djonehub/voice-runtime/*.ko; "
            "mount -o remount,rw /; "
            "cp /data/local/tmp/djonehub_agent.new /etc/init.d/.djonehub_agent.new; "
            "chmod 755 /etc/init.d/.djonehub_agent.new; "
            "mv /etc/init.d/.djonehub_agent.new /etc/init.d/djonehub_agent; "
            "ln -sfn ../init.d/djonehub_agent /etc/rc5.d/S99zz_djonehub_agent; "
            "sync; "
            "mount -o remount,ro /; "
            "grep -q 'ubi0:rootfs / ubifs ro,' /proc/mounts"
        )
        # Mac 完整模式需要等待最多 45 秒确认 USB 不会切换为移动组合。
        transport.shell("/etc/init.d/djonehub_agent start", timeout_seconds=60)
        status = transport.shell(
            "/etc/init.d/djonehub_agent status; "
            f"test \"$(pidof ql_manager_server)\" = {shlex.quote(factory_pid)}; "
            "functions=$(cat /sys/devices/virtual/android_usb/android0/functions); "
            "case ,$functions, in *,audio,*) ;; *) exit 51;; esac; "
            "case ,$functions, in *,serial,*) ;; *) exit 52;; esac; "
            "echo \"functions=$functions\"",
            timeout_seconds=20,
        )
        if "mac-pass-through" not in status:
            raise RuntimeError(f"Mac 透传模式验证失败：{status}")
        print("永久启动器已安装；当前保持 Mac 完整模式，原厂服务未重启。", flush=True)
    except Exception:
        if committed:
            try:
                transport.shell(
                    "/etc/init.d/djonehub_agent stop 2>/dev/null || true; "
                    "mount -o remount,rw /; "
                    "rm -f /etc/rc5.d/S99djonehub_agent /etc/rc5.d/S99zz_djonehub_agent /etc/init.d/djonehub_agent /etc/init.d/.djonehub_agent.new; "
                    "sync; mount -o remount,ro /"
                )
                if plan is not None:
                    newly_added_paths = [
                        final_path
                        for name, _, _, final_path, _ in deployment_entries
                        if name in plan.stage_names and final_path not in preexisting_paths
                    ]
                    if newly_added_paths:
                        transport.shell(
                            "rm -f "
                            + " ".join(shlex.quote(path) for path in newly_added_paths)
                        )
                if recovery_agent_data is not None:
                    rollback_path = "/data/local/tmp/qdc507-agent.rollback"
                    transport.push(recovery_agent_data, rollback_path, 0o755)
                    transport.shell(
                        f"mv {rollback_path} /data/djonehub/bin/qdc507-agent; sync"
                    )
                current_factory_pid = transport.shell("pidof ql_manager_server").strip()
                if factory_pid and current_factory_pid != factory_pid:
                    print(
                        f"警告：回滚后原厂服务 PID 变化：{factory_pid} -> {current_factory_pid}",
                        file=sys.stderr,
                    )
            except Exception as rollback_error:
                print(f"警告：自动回滚也失败：{rollback_error}", file=sys.stderr)
        raise
    finally:
        transport.close()


def update_installed_runtime() -> None:
    """原子更新已安装的 Agent 与网络 PCM helper，不重启原厂服务或切换 USB。"""
    files = verify_local_files()
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    factory_pid = ""
    functions_before = ""
    # 每次更新都保留独立恢复点；固定目录会让第二次合法更新必然失败。
    backup_directory = (
        f"/data/djonehub/backup/pre-network-pcm-{int(time.time())}-"
        f"{secrets.token_hex(3)}"
    )
    committed = False
    agent_hash = files[AGENT_PATH]
    helper_path = VOICE_SOURCES["mavo-pcm-bridge.armv7"]
    helper_hash = files[helper_path]
    try:
        identity = transport.shell("id -u; uname -m; uname -r")
        if identity.replace("\r", "") != "0\narmv7l\n3.18.44":
            raise RuntimeError(f"模块身份不符合已验证目标：\n{identity}")
        factory_pid = transport.shell("pidof ql_manager_server").strip()
        if not re.fullmatch(r"[0-9]+", factory_pid):
            raise RuntimeError(f"原厂 ql_manager_server 状态异常：{factory_pid!r}")
        functions_before = transport.shell(
            "cat /sys/devices/virtual/android_usb/android0/functions"
        ).strip()
        for required_function in ("audio", "serial", "ecm"):
            if required_function not in functions_before.split(","):
                raise RuntimeError(
                    f"当前不是 Mac 完整 USB 组合，缺少 {required_function}："
                    f"{functions_before}"
                )
        # 预检必须失败即终止，避免前置失败被最后一个成功命令覆盖。
        transport.shell(
            "set -e; "
            "test -x /etc/init.d/djonehub_agent; "
            "test -x /data/djonehub/bin/qdc507-agent; "
            "test -x /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; "
            "test -z \"$(pidof qdc507-agent 2>/dev/null)\"; "
            "test ! -s /run/mavo-voice-route.pid || "
            "! kill -0 \"$(cat /run/mavo-voice-route.pid)\" 2>/dev/null"
        )
        installed_hashes = transport.shell(
            "busybox sha256sum /data/djonehub/bin/qdc507-agent "
            "/data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 | "
            "awk '{print $1}'"
        ).replace("\r", "").splitlines()
        if installed_hashes == [agent_hash, helper_hash]:
            print("模块 Agent 与网络 PCM helper 已是目标版本，无需重复更新。")
            return
        transport.shell(f"test ! -e {shlex.quote(backup_directory)}")

        # 只在无通话时更新；此探针不会停止或重启 ql_manager_server。
        call_check = transport.shell(
            "(sleep 1; printf 'block_check_condition call_state NONE\\n'; "
            "sleep 1; printf 'quit\\n') | timeout -t 8 "
            "/usr/bin/qmi_simple_ril_test 2>&1 | tail -n 40",
            timeout_seconds=15,
        )
        if "TRUE" not in call_check:
            raise RuntimeError("模块可能正在通话，拒绝更新运行时")

        # 新旧文件和备份均位于同一 UBI 卷，提交阶段只做 rename；这里只需为目录项与日志保留余量。
        staging_margin_bytes = 128 * 1024
        required_bytes = (
            AGENT_PATH.stat().st_size
            + helper_path.stat().st_size
            + staging_margin_bytes
        )
        available_kib = int(
            transport.shell("df -Pk /data | awk 'NR==2 {print $4}'").strip()
        )
        if available_kib * 1024 < required_bytes:
            raise RuntimeError(
                f"/data 剩余空间不足：需要至少 {required_bytes} 字节，"
                f"实际 {available_kib * 1024} 字节"
            )

        staged_files = (
            (AGENT_PATH, "/data/local/tmp/qdc507-agent.runtime-new", 0o755, agent_hash),
            (
                helper_path,
                "/data/local/tmp/mavo-pcm-bridge.armv7.runtime-new",
                0o755,
                helper_hash,
            ),
        )
        for local_path, remote_path, mode, expected_hash in staged_files:
            current_hash = transport.shell(
                f"test ! -f {shlex.quote(remote_path)} || "
                f"busybox sha256sum {shlex.quote(remote_path)} | awk '{{print $1}}'"
            ).strip()
            if current_hash != expected_hash:
                print(f"推送 {local_path.name} ...", flush=True)
                transport.push(local_path.read_bytes(), remote_path, mode)
            uploaded_hash = transport.shell(
                f"busybox sha256sum {shlex.quote(remote_path)} | awk '{{print $1}}'"
            ).strip()
            if uploaded_hash != expected_hash:
                raise RuntimeError(f"模块端 SHA-256 不匹配：{local_path.name}")

        preflight = transport.shell(
            "/data/local/tmp/qdc507-agent.runtime-new --startup-probe runtime 2>&1; "
            "/data/local/tmp/mavo-pcm-bridge.armv7.runtime-new --check 2>&1"
        )
        verify_runtime_probe(preflight, helper_hash)
        if transport.shell("pidof ql_manager_server").strip() != factory_pid:
            raise RuntimeError("提交前原厂 ql_manager_server PID 发生变化")

        committed = True
        transport.shell(
            "set -e; "
            f"mkdir {shlex.quote(backup_directory)}; "
            f"mv /data/djonehub/bin/qdc507-agent {shlex.quote(backup_directory)}/qdc507-agent; "
            f"mv /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 {shlex.quote(backup_directory)}/mavo-pcm-bridge.armv7; "
            "mv /data/local/tmp/qdc507-agent.runtime-new /data/djonehub/bin/qdc507-agent; "
            "mv /data/local/tmp/mavo-pcm-bridge.armv7.runtime-new /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; "
            "chmod 755 /data/djonehub/bin/qdc507-agent "
            "/data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; sync"
        )
        verified = transport.shell(
            f"test \"$(busybox sha256sum /data/djonehub/bin/qdc507-agent | awk '{{print $1}}')\" = {agent_hash}; "
            f"test \"$(busybox sha256sum /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 | awk '{{print $1}}')\" = {helper_hash}; "
            "/data/djonehub/bin/qdc507-agent --startup-probe runtime 2>&1; "
            "/data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 --check 2>&1; "
            f"test \"$(pidof ql_manager_server)\" = {shlex.quote(factory_pid)}; "
            "printf 'functions='; cat /sys/devices/virtual/android_usb/android0/functions"
        )
        if f"functions={functions_before}" not in verified.replace("\r", ""):
            raise RuntimeError(f"运行时更新意外改变了当前 USB 组合：{verified}")
        print(
            f"Agent 与网络 PCM helper 已原子更新；原厂服务 PID={factory_pid} 未变化。\n"
            f"{verified}"
        )
    except Exception:
        if committed:
            try:
                # 提交失败时保留失败产物供诊断，并把更新前文件原子放回正式路径。
                transport.shell(
                    "test ! -f /data/djonehub/bin/qdc507-agent || "
                    "mv /data/djonehub/bin/qdc507-agent /data/local/tmp/qdc507-agent.runtime-failed; "
                    "test ! -f /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 || "
                    "mv /data/djonehub/voice-runtime/mavo-pcm-bridge.armv7 "
                    "/data/local/tmp/mavo-pcm-bridge.armv7.runtime-failed; "
                    f"test ! -f {shlex.quote(backup_directory)}/qdc507-agent || "
                    f"mv {shlex.quote(backup_directory)}/qdc507-agent /data/djonehub/bin/qdc507-agent; "
                    f"test ! -f {shlex.quote(backup_directory)}/mavo-pcm-bridge.armv7 || "
                    f"mv {shlex.quote(backup_directory)}/mavo-pcm-bridge.armv7 "
                    "/data/djonehub/voice-runtime/mavo-pcm-bridge.armv7; sync"
                )
                if factory_pid and transport.shell("pidof ql_manager_server").strip() != factory_pid:
                    print("警告：回滚后原厂服务 PID 发生变化", file=sys.stderr)
            except Exception as rollback_error:
                print(f"警告：运行时自动回滚失败：{rollback_error}", file=sys.stderr)
        raise
    finally:
        transport.close()


def update_startup_hook() -> None:
    """只更新已部署的双模式启动器，并保持原厂服务与当前 Mac USB 组合不变。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    temporary_path = "/data/local/tmp/djonehub_agent.new"
    expected_hash = hashlib.sha256(INIT_SCRIPT.encode("utf-8")).hexdigest()
    try:
        identity = transport.shell("id -u; uname -m; uname -r")
        if identity.replace("\r", "") != "0\narmv7l\n3.18.44":
            raise RuntimeError(f"模块身份不符合已验证目标：\n{identity}")
        factory_pid = transport.shell("pidof ql_manager_server").strip()
        if not re.fullmatch(r"[0-9]+", factory_pid):
            raise RuntimeError(f"原厂 ql_manager_server 状态异常：{factory_pid!r}")
        functions_before = transport.shell(
            "cat /sys/devices/virtual/android_usb/android0/functions"
        ).strip()
        transport.shell(
            "test -x /etc/init.d/djonehub_agent; "
            "link=$(readlink /etc/rc5.d/S99zz_djonehub_agent 2>/dev/null || "
            "readlink /etc/rc5.d/S99djonehub_agent 2>/dev/null); "
            "test \"$link\" = ../init.d/djonehub_agent"
        )
        transport.push(INIT_SCRIPT.encode("utf-8"), temporary_path, 0o755)
        uploaded_hash = transport.shell(
            f"busybox sha256sum {temporary_path} | awk '{{print $1}}'"
        ).strip()
        if uploaded_hash != expected_hash:
            raise RuntimeError("启动器上传后的 SHA-256 不匹配")

        # 固定保留一份首次升级前备份；根分区只在原子替换期间临时改为可写。
        transport.shell(
            "set -e; "
            "test -f /data/djonehub/backup/djonehub_agent.before-profile-wait || "
            "cp /etc/init.d/djonehub_agent /data/djonehub/backup/djonehub_agent.before-profile-wait; "
            "restore_ro() { mount -o remount,ro / >/dev/null 2>&1 || true; }; "
            "trap restore_ro 0 1 2 3 15; "
            "mount -o remount,rw /; "
            f"cp {temporary_path} /etc/init.d/.djonehub_agent.new; "
            "chmod 755 /etc/init.d/.djonehub_agent.new; "
            "mv /etc/init.d/.djonehub_agent.new /etc/init.d/djonehub_agent; "
            "rm -f /etc/rc5.d/S99djonehub_agent; "
            "ln -sfn ../init.d/djonehub_agent /etc/rc5.d/S99zz_djonehub_agent; "
            "sync; mount -o remount,ro /; "
            "grep -q 'ubi0:rootfs / ubifs ro,' /proc/mounts"
        )
        # 旧启动器可能仍在本次启动的 45 秒等待中；只终止精确匹配的旧 start shell，
        # 防止它按旧逻辑再次剥离 serial/audio。原厂服务与 Agent 进程均不在匹配范围。
        stopped_waiters = transport.shell(
            "stopped=0; "
            "for process in /proc/[0-9]*; do "
            # /proc 中的进程可能在遍历期间退出；让 cat 负责打开文件，避免 shell 重定向竞态报错。
            "  cmdline=$(cat \"$process/cmdline\" 2>/dev/null | tr '\\000' '\\n'); "
            "  argv1=$(printf '%s\\n' \"$cmdline\" | sed -n '2p'); "
            "  argv2=$(printf '%s\\n' \"$cmdline\" | sed -n '3p'); "
            "  case \"$argv1:$argv2\" in "
            "    /etc/init.d/djonehub_agent:start|/etc/rc5.d/S99djonehub_agent:start|"
            "/etc/rc5.d/S99zz_djonehub_agent:start) "
            # 精确 PID 可能在发信号前自行结束；这不应使启动器更新被误判为失败。
            "      if kill -TERM \"${process##*/}\" 2>/dev/null; then stopped=$((stopped+1)); fi;; "
            "  esac; "
            "done; sleep 0.3; echo stopped_start_waiters=$stopped"
        )
        status = transport.shell(
            f"test \"$(busybox sha256sum /etc/init.d/djonehub_agent | awk '{{print $1}}')\" = {expected_hash}; "
            f"test \"$(pidof ql_manager_server)\" = {shlex.quote(factory_pid)}; "
            "test \"$(readlink /etc/rc5.d/S99zz_djonehub_agent)\" = ../init.d/djonehub_agent; "
            "printf 'functions='; cat /sys/devices/virtual/android_usb/android0/functions"
        )
        if f"functions={functions_before}" not in status.replace("\r", ""):
            raise RuntimeError(f"启动器更新意外改变了当前 USB 组合：{status}")
        print(
            f"双模式启动器已更新；原厂服务 PID={factory_pid} 未变化。\n"
            f"{stopped_waiters}\n{status}"
        )
    finally:
        transport.close()


def inspect_startup_hooks() -> None:
    """只读列出固件会从持久分区读取或执行的启动入口。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "grep -R -n -E '/data|/cache|/usrdata' /etc/init.d /etc/rcS.d /etc/rc5.d /etc/inittab 2>/dev/null || true; "
                "echo __READ_ONLY_ROOTFS_HOOK__; sed -n '1,260p' /etc/init.d/read-only-rootfs-hook.sh; "
                "echo __MOUNTALL__; sed -n '1,260p' /etc/init.d/mountall.sh; "
                "echo __FIND_PARTITIONS__; grep -n -C 12 -E 'bind_flag|/data|/cache|usrdata' /etc/init.d/find_partitions.sh || true; "
                "echo __DJONEHUB_STATE__; ls -l /etc/init.d/djonehub_agent /etc/rc5.d/S99*djonehub_agent /data/djonehub/bin/qdc507-agent 2>&1 || true; "
                "command -v nohup 2>&1 || true; command -v start-stop-daemon 2>&1 || true; ls -l /data/djonehub/log 2>&1 || true; "
                "tail -n 120 /data/djonehub/log/agent.log 2>/dev/null || true; "
                "echo __FILES__; "
                "find /data /cache /usrdata -maxdepth 3 -type f -o -type l 2>/dev/null | sort | head -n 300",
                timeout_seconds=30,
            )
        )
    finally:
        transport.close()


def inspect_mobile_start_failure() -> None:
    """只读收集移动启动判定相关状态，禁止重绑 USB 或停止原厂服务。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __USB_GADGET__; "
                "printf 'functions='; cat /sys/devices/virtual/android_usb/android0/functions 2>&1; "
                "printf 'audio_enable='; cat /sys/class/android_usb/android0/f_audio/audio_enable 2>&1; "
                "printf 'enabled='; cat /sys/devices/virtual/android_usb/android0/enable 2>&1; "
                "echo __USB_ATTRIBUTES__; "
                "find -L /sys/class/android_usb/android0 -maxdepth 3 -type f 2>/dev/null | sort | "
                "while read path; do value=$(cat \"$path\" 2>/dev/null); "
                "case \"$value\" in *[![:print:]]*) continue;; esac; "
                "printf '%s=%s\\n' \"$path\" \"$value\"; done; "
                "echo __PERSISTED_USB__; "
                "for path in /data/usb/boot_hsusb_composition /data/usb/hsusb_next "
                "/data/usb/quec_usbmode_check /data/mobileap_cfg /data/mobileap_cfg.xml; do "
                "echo ---$path; sed -n '1,160p' \"$path\" 2>/dev/null || true; done; "
                "echo __SERVICE__; /etc/init.d/djonehub_agent status 2>&1; echo status_code=$?; "
                "printf 'agent_pid='; pidof qdc507-agent 2>/dev/null || true; "
                "printf 'factory_pid='; pidof ql_manager_server 2>/dev/null || true; "
                "echo __FACTORY_INIT__; "
                "ls -l /etc/rc5.d/*ql_manager* /etc/init.d/*ql_manager* 2>&1 || true; "
                "for path in /etc/init.d/*ql_manager*; do test -f \"$path\" || continue; "
                "echo ---$path; sed -n '1,260p' \"$path\"; done; "
                "echo __PROCESSES__; ps w 2>/dev/null | grep -E 'ql_manager|qmi|ril|atfwd' || true; "
                "echo __PIDFILE__; cat /run/djonehub-agent.pid 2>&1 || true; "
                "echo __MODULES__; grep -E 'qdc507_data11_bridge|g_smd' /proc/modules 2>/dev/null || true; "
                "echo __DEVICE__; ls -l /dev/djonehub_data11 2>&1 || true; "
                "echo __LISTEN__; netstat -lntp 2>/dev/null | grep ':7575' || true; "
                "echo __STARTUP_LOG__; tail -n 120 /data/djonehub/log/startup.log 2>/dev/null || true; "
                "echo __AGENT_LOG__; tail -n 120 /data/djonehub/log/agent.log 2>/dev/null || true; "
                "echo __KERNEL_LOG__; dmesg | grep -E -i 'djonehub|data11|g_smd|smd' | tail -n 160 || true",
                timeout_seconds=30,
            )
        )
    finally:
        transport.close()


def inspect_startup_result() -> None:
    """轻量读取双模式启动结果，供重启后的等待循环使用。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "printf 'functions='; cat /sys/devices/virtual/android_usb/android0/functions 2>&1; "
                "printf 'serial_connected='; cat /sys/devices/virtual/android_usb/android0/f_serial/is_connected_flag 2>&1; "
                "printf 'factory_pid='; pidof ql_manager_server 2>/dev/null || true; "
                "printf 'agent_pid='; pidof qdc507-agent 2>/dev/null || true; "
                "printf 'listen_7575='; netstat -lntp 2>/dev/null | grep ':7575' || true; "
                "echo launch_tools:; command -v setsid 2>/dev/null || true; "
                "start-stop-daemon --help 2>&1 | head -n 30 || true; "
                "echo init_processes:; ps w 2>/dev/null | grep -E 'djonehub_agent|wait_factory_service' || true; "
                "echo manual_start_log:; tail -n 40 /data/djonehub/log/manual-start.log 2>/dev/null || true; "
                "echo startup_log:; tail -n 20 /data/djonehub/log/startup.log 2>/dev/null || true; "
                "echo agent_log:; tail -n 40 /data/djonehub/log/agent.log 2>/dev/null || true",
                timeout_seconds=15,
            )
        )
    finally:
        transport.close()


def start_mobile_now() -> None:
    """在已确认的移动组合上异步启动 Agent；重绑前严格保护原厂服务与通话。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        profile = transport.shell(
            "functions=$(cat /sys/devices/virtual/android_usb/android0/functions); "
            "case ,$functions, in *,ecm,*) ;; *) exit 41;; esac; "
            "case ,$functions, in *,audio,*) exit 42;; esac; "
            "printf '%s' \"$functions\""
        )
        factory_pid = transport.shell("pidof ql_manager_server").strip()
        if not re.fullmatch(r"[0-9]+", factory_pid):
            raise RuntimeError(f"原厂 ql_manager_server 状态异常：{factory_pid!r}")
        call_check = transport.shell(
            "(sleep 1; printf 'block_check_condition call_state NONE\\n'; "
            "sleep 1; printf 'quit\\n') | timeout -t 8 "
            "/usr/bin/qmi_simple_ril_test 2>&1 | tail -n 40",
            timeout_seconds=15,
        )
        if "TRUE" not in call_check:
            raise RuntimeError("模块可能正在通话，拒绝重绑移动 USB 组合")
        # setsid 建立独立会话；不能用 start-stop-daemon -x 匹配 BusyBox 符号链接，否则会误判已有进程。
        transport.shell(
            "setsid /bin/sh /etc/init.d/djonehub_agent start "
            ">/data/djonehub/log/manual-start.log 2>&1 </dev/null & "
            "launcher=$!; sleep 1; kill -0 \"$launcher\" 2>/dev/null || true; echo started"
        )
        print(f"已触发移动 Agent：functions={profile}；原厂服务 PID={factory_pid}")
    finally:
        transport.close()


def inspect_at_channels() -> None:
    """只读枚举 SMD 通道名称与占用者，为模块内 eUICC 选择正确 AT 端口。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __SMD_CHANNELS__; "
                "for tty in /sys/class/tty/smd*; do "
                "  test -e \"$tty\" || continue; "
                "  echo ---${tty##*/}---; "
                "  cat \"$tty/device/name\" 2>/dev/null || true; "
                "  cat \"$tty/device/uevent\" 2>/dev/null || true; "
                "  readlink -f \"$tty/device\" 2>/dev/null || true; "
                "done; "
                "echo __SMD_OWNERS__; "
                "for process_dir in /proc/[0-9]*; do "
                "  process_id=${process_dir##*/}; process_name=$(cat \"$process_dir/comm\" 2>/dev/null); "
                "  for descriptor in \"$process_dir\"/fd/*; do "
                "    target=$(readlink \"$descriptor\" 2>/dev/null); "
                "    case \"$target\" in /dev/smd*) echo \"pid=$process_id process=$process_name fd=${descriptor##*/} target=$target\";; esac; "
                "  done; "
                "done; "
                "echo __USB_AND_RIL__; "
                "ps w 2>/dev/null | grep -E 'ql_manager|ril|atfwd|port_bridge' | grep -v grep || true; "
                # 这两个路径在部分固件中是 ELF 工具而不是配置文本，禁止直接 cat。
                "for path in /data/usb/boot_hsusb_composition /data/usb/hsusb_next; do "
                "  test -e \"$path\" || continue; "
                "  echo \"---$path---\"; ls -l \"$path\"; "
                "  busybox strings \"$path\" 2>/dev/null | head -n 40 || true; "
                "done"
            )
        )
    finally:
        transport.close()


def inspect_vendor_ipc() -> None:
    """只读调查原厂管理服务、QMI/QRTR 入口与 UIM/APDU 能力。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __VENDOR_PROCESSES__; "
                "ps w 2>/dev/null | grep -E 'ql_manager|qmi|ril|qrtr|ipc_router' | grep -v grep || true; "
                "echo __UNIX_SOCKETS__; "
                "cat /proc/net/unix 2>/dev/null | grep -Ei 'ql|qmi|ril|uim|sim|at|manager' || true; "
                "echo __QMI_QRTR_DEVICES__; "
                "find /dev -maxdepth 2 \\( -iname '*qmi*' -o -iname '*wdm*' -o -iname '*qrtr*' -o -iname '*ipc*' -o -iname '*uim*' -o -iname '*rmnet*' \\) "
                "  -exec ls -ld {} \\; 2>/dev/null | head -n 240; "
                "echo __KERNEL_SUPPORT__; "
                "grep -Ei 'qrtr|qipcrtr|msm_ipc|ipc_router|qmi' /proc/net/protocols /proc/modules 2>/dev/null || true; "
                "for path in /sys/module/qrtr /sys/module/msm_ipc_router /sys/module/ipc_router; do "
                "  test ! -e \"$path\" || ls -ld \"$path\"; "
                "done; "
                "echo __OPEN_DESCRIPTORS__; "
                "for process_name in ql_manager_server qmi_simple_ril_test; do "
                "  for process_id in $(pidof \"$process_name\" 2>/dev/null); do "
                "    echo \"---$process_name pid=$process_id---\"; "
                "    for descriptor in /proc/$process_id/fd/*; do "
                "      target=$(readlink \"$descriptor\" 2>/dev/null); "
                "      test -z \"$target\" || echo \"fd=${descriptor##*/} target=$target\"; "
                "    done; "
                "  done; "
                "done; "
                "echo __BINARY_CAPABILITIES__; "
                "for path in /usr/bin/ql_manager_cli /usr/bin/ql_manager_server /usr/lib/libql_mgmt_client.so.1.0.0 /usr/bin/qmi_simple_ril_test; do "
                "  test -e \"$path\" || continue; "
                "  echo \"---$path---\"; ls -l \"$path\"; "
                "  busybox strings \"$path\" 2>/dev/null | "
                "    grep -Ei 'socket|/tmp/|/run/|/var/|uim|euicc|esim|logical.?channel|open.?channel|apdu|sim.?slot|qmi|at.?command' | "
                "    head -n 220 || true; "
                "done",
                timeout_seconds=30,
            )
        )
    finally:
        transport.close()


def inspect_qmi_console() -> None:
    """只读获取原厂 QMI 测试控制台帮助及 APDU 命令附近的静态文本。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __QMI_CONSOLE_HELP__; "
                "(sleep 1; printf 'help\\n?\\nqmi_svc_versions\\nquit\\n') | "
                "  timeout -t 15 /usr/bin/qmi_simple_ril_test 2>&1 | tail -n 500",
                timeout_seconds=25,
            )
        )
        binary = transport.pull("/usr/bin/qmi_simple_ril_test")
        # 在 Mac 侧保留偏移并打印关键词邻域，不依赖模块精简版 BusyBox 的 nl/sed 功能。
        values = [
            (match.start(), match.group().decode("ascii", errors="replace"))
            for match in re.finditer(rb"[\x20-\x7e]{4,}", binary)
        ]
        selected: set[int] = set()
        keyword = re.compile(
            r"send_apdu|logical_channel|command|usage|session|slot|aid|channel",
            re.IGNORECASE,
        )
        for index, (_, value) in enumerate(values):
            if keyword.search(value):
                selected.update(range(max(0, index - 16), min(len(values), index + 17)))
        print("__APDU_NEARBY_STRINGS__")
        for index in sorted(selected):
            offset, value = values[index]
            print(f"0x{offset:08x} {value}")
    finally:
        transport.close()


def probe_qmi_logical_channel() -> None:
    """通过原厂 QMI 控制台只读打开并立即关闭 eUICC 2 logical channel。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        # qmi_simple_ril_test 以逐字节数值接收 AID；这里固定为已验证的 eUICC 2。
        aid = "A0 65 73 74 6B 6D 65 FF FF 49 53 44 2D 52 20 31"
        aid_arguments = " ".join(f"0x{value}" for value in aid.split())
        command = (
            "base=/data/local/tmp/djonehub-qmi-channel-$$; "
            "input=$base.in; output=$base.log; "
            "cleanup() { "
            "  exec 3>&- 2>/dev/null || true; "
            "  test -z \"${console_pid:-}\" || kill -TERM \"$console_pid\" 2>/dev/null || true; "
            "  rm -f \"$input\" \"$output\"; "
            "}; trap cleanup 0 1 2 3 15; "
            "mkfifo \"$input\"; "
            "timeout -t 20 /usr/bin/qmi_simple_ril_test <\"$input\" >\"$output\" 2>&1 & "
            "console_pid=$!; exec 3>\"$input\"; sleep 2; "
            # 原厂数值解析器默认按十六进制处理，AID 的 16 字节长度必须写成 0x10。
            f"printf 'logical_channel 2 0x10 {aid_arguments}\\n' >&3; "
            "n=0; while test \"$n\" -lt 40; do "
            "  grep -q 'channel_id: 0x' \"$output\" 2>/dev/null && break; "
            "  grep -q 'logical_channel req returned error' \"$output\" 2>/dev/null && break; "
            "  kill -0 \"$console_pid\" 2>/dev/null || break; "
            "  sleep 0.25; n=$((n+1)); "
            "done; "
            "channel=$(sed -n 's/.*channel_id: 0x\\([0-9A-Fa-f][0-9A-Fa-f]*\\).*/\\1/p' \"$output\" | tail -n 1); "
            "if test -n \"$channel\"; then "
            "  printf 'logical_channel 2 0x%s\\n' \"$channel\" >&3; sleep 1; "
            "fi; "
            "printf 'quit\\n' >&3; wait \"$console_pid\" 2>/dev/null || true; console_pid=; "
            "cat \"$output\"; "
            "test -n \"$channel\""
        )
        print(transport.shell(command, timeout_seconds=30))
    finally:
        transport.close()


def inspect_modem_routing() -> None:
    """只读追踪 USB AT、ATFWD 与 SMD 通道的固件映射关系。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __TTY_DRIVERS__; cat /proc/tty/drivers 2>/dev/null || true; "
                "echo __SMD_SYSFS__; "
                "for tty in /sys/class/tty/smd*; do "
                "  test -e \"$tty\" || continue; "
                "  echo \"---${tty##*/}---\"; "
                "  ls -ld \"$tty\" \"$tty/device\" \"$tty/device/driver\" 2>/dev/null || true; "
                "  find \"$tty/device\" -maxdepth 2 -type f 2>/dev/null | sort | while read path; do "
                "    case \"$path\" in */uevent|*/dev|*/name|*/modalias) "
                "      echo \"[$path]\"; busybox strings \"$path\" 2>/dev/null | head -n 20;; "
                "    esac; "
                "  done; "
                "done; "
                "echo __DEBUG_ROUTES__; "
                "find /sys/kernel/debug -maxdepth 4 \\( -iname '*smd*' -o -iname '*ipc*' -o -iname '*at*' \\) "
                "  -print 2>/dev/null | head -n 240; "
                "echo __DEBUG_STATUS__; "
                "for path in /sys/kernel/debug/usb_gsmd/status /sys/kernel/debug/usb_serial0/readstatus "
                "  /sys/kernel/debug/usb_qti/status /sys/kernel/debug/usb_rmnet_ctrl_smd/status "
                "  /sys/kernel/debug/smd/int_stats /sys/kernel/debug/msm_ipc_router/*; do "
                "  test -f \"$path\" || continue; echo \"---$path---\"; "
                "  busybox strings \"$path\" 2>/dev/null | head -n 180 || true; "
                "done; "
                "echo __SMD_DEBUG_TREE__; "
                "ls -la /sys/kernel/debug/smd /sys/kernel/debug/usb_gsmd 2>/dev/null || true; "
                "find /sys/kernel/debug/smd /sys/kernel/debug/usb_gsmd -maxdepth 3 -type f 2>/dev/null | "
                "  sort | while read path; do "
                "    echo \"---$path---\"; busybox strings \"$path\" 2>/dev/null | head -n 120 || true; "
                "  done; "
                "echo __KERNEL_LOG_ROUTES__; "
                "dmesg 2>/dev/null | grep -Ei 'usb.*smd|smd.*usb|g_smd|gsmd|smd.*open|opening.*smd|DATA[0-9]+' | tail -n 260 || true; "
                "echo __USB_FUNCTIONS__; "
                "ls -l /sys/devices/virtual/android_usb/android0/enable "
                "  /sys/devices/virtual/android_usb/android0/functions "
                "  /sys/devices/virtual/android_usb/android0/f_serial/transports 2>/dev/null || true; "
                "for path in /sys/devices/virtual/android_usb/android0/functions "
                "  /sys/devices/virtual/android_usb/android0/f_*/transports "
                "  /sys/devices/virtual/android_usb/android0/f_*/transport_names "
                "  /sys/module/g_smd/parameters/* /sys/module/u_serial/parameters/*; do "
                "  test -f \"$path\" || continue; echo \"---$path---\"; "
                "  busybox strings \"$path\" 2>/dev/null | head -n 80 || true; "
                "done; "
                "echo __DEVICE_TREE_ROUTES__; "
                "find /proc/device-tree -type f 2>/dev/null | grep -Ei 'smd|serial|usb|ipc|bam' | head -n 240; "
                "echo __CONFIG_REFERENCES__; "
                "grep -R -n -E '/dev/smd[0-9]+|smd[0-9]+|atfwd|hsusb' /etc/init.d /etc/udev /data/usb 2>/dev/null | head -n 320 || true; "
                "echo __MODEM_TOOLS__; "
                "find /usr/bin /usr/sbin -maxdepth 1 -type f 2>/dev/null | "
                "  grep -Ei '/(at|.*at|ril|.*ril|qmi|.*qmi|usb|.*usb|sim|.*sim|estk|.*estk|port|.*port)' | sort | head -n 260; "
                "echo __ATFWD_STRINGS__; "
                "for path in /usr/bin/atfwd_daemon /usr/bin/usb_composition_switch /usr/bin/ql_usbcfg "
                "  /usr/lib/lib.*at.*so* /usr/lib/lib.*ril.*so*; do "
                "  test -f \"$path\" || continue; echo \"---$path---\"; "
                "  busybox strings \"$path\" 2>/dev/null | "
                "    grep -Ei '/dev/smd|smd[0-9]+|atcop|at.?command|socket|qmi|uim|sim|usb' | head -n 180 || true; "
                "done",
                timeout_seconds=35,
            )
        )
    finally:
        transport.close()


def correlate_usb_at_channel() -> None:
    """用无副作用 AT 探针与 SMD 指针差分确认 USB AT 对应的内部通道。"""
    def snapshot() -> str:
        # 子进程退出后 libusb 才会彻底释放设备，随后 Mac 后台才能重新声明 AT 接口。
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--print-smd-data"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip()

    before = snapshot()
    time.sleep(2.2)
    # ADB 声明过设备后，先触发 Mac 后台重新发现 USB AT 接口。
    health_result = subprocess.run(
        ["curl", "--max-time", "5", "-fsS", "http://127.0.0.1:7575/api/health"],
        check=True,
        capture_output=True,
    )
    health = health_result.stdout
    if b'"ok":true' not in health:
        raise RuntimeError(f"Mac USB 重新发现失败：{health!r}")
    time.sleep(0.3)
    for _ in range(1):
        for attempt in range(5):
            result = subprocess.run(
                [
                    "curl", "--max-time", "5", "-fsS", "-X", "POST",
                    "-H", "Content-Type: application/json",
                    "-d", '{"command":"AT"}',
                    "http://127.0.0.1:7575/api/at",
                ],
                capture_output=True,
            )
            if result.returncode == 0:
                payload = result.stdout
                if b"OK" not in payload:
                    raise RuntimeError(f"Mac USB AT 探针返回异常：{payload!r}")
                break
            if attempt == 4:
                raise RuntimeError(
                    f"Mac USB AT 探针失败：{result.stderr.decode(errors='replace')}"
                )
            time.sleep(1.0)
        time.sleep(0.8)
    time.sleep(0.8)
    after = snapshot()
    print("__SMD_BEFORE__")
    print(before)
    print("__SMD_AFTER__")
    print(after)


def print_smd_data() -> None:
    """为 USB/SMD 差分子进程输出 DATA 通道快照。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "cat /sys/kernel/debug/smd/ch 2>/dev/null | "
                "grep -E '\\|DATA[0-9 ]+' || true"
            )
        )
    finally:
        transport.close()


def probe_smd21_open() -> None:
    """只打开并立即关闭 DATA11 的 tty 映射，不发送任何 AT 数据。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "set +e; "
                "timeout -t 2 sh -c 'exec 9<>/dev/smd21; echo SMD21_OPENED; sleep 0.1'; "
                "code=$?; echo open_exit=$code; test \"$code\" -eq 0"
            )
        )
    finally:
        transport.close()


def probe_smd21_detached() -> None:
    """临时关闭 USB gadget 后只打开 DATA11，并由 trap 无条件恢复 gadget。"""
    launch_domain = f"gui/{os.getuid()}"
    launch_label = f"{launch_domain}/com.jamie.djonehub"
    launch_plist = Path.home() / "Library/LaunchAgents/com.jamie.djonehub.plist"
    log_path = "/data/local/tmp/djonehub-smd21-detached.log"
    script_path = "/data/local/tmp/djonehub-smd21-detached.sh"
    script = f"""#!/bin/sh
# 临时释放 USB gadget 后验证 DATA11，任何退出路径都恢复 gadget。
enable=/sys/devices/virtual/android_usb/android0/enable
functions=/sys/devices/virtual/android_usb/android0/functions
transports=/sys/devices/virtual/android_usb/android0/f_serial/transports
log={log_path}
original_functions=$(cat "$functions")
original_transports=$(cat "$transports")
exec >"$log" 2>&1
echo __LAUNCHED__
restore() {{
    echo 0 >"$enable" 2>/dev/null || true
    echo "$original_transports" >"$transports" 2>/dev/null || true
    echo "$original_functions" >"$functions" 2>/dev/null || true
    echo 1 >"$enable" 2>/dev/null || true
}}
trap restore 0 1 2 3 15

# 给启动当前脚本的 ADB shell 留出返回确认的时间，再解除 USB gadget。
sleep 2
sleep 2
echo __BEFORE__
cat "$enable"
echo 0 >"$enable"
sleep 0.5
echo tty >"$transports"
echo diag,ecm,ffs,audio >"$functions"
sleep 1
echo __SMD_AFTER_UNBIND__
cat /sys/kernel/debug/smd/ch 2>/dev/null | grep -E '\\|DATA[0-9 ]+' || true
echo __OPEN_TEST__
for device in /dev/smd9 /dev/smd10 /dev/smd21 /dev/smd36; do
    echo "---$device---"
    if timeout -t 2 sh -c "exec 9<>$device; echo DEVICE_OPENED; sleep 0.1"; then
        echo open_exit=0
    else
        code=$?
        echo open_exit=$code
    fi
done
echo __RESTORE__
restore
sleep 1
cat "$enable"
sync
"""
    paused_backend = False
    try:
        if launch_plist.is_file():
            result = subprocess.run(
                ["launchctl", "bootout", launch_label],
                capture_output=True,
                text=True,
            )
            paused_backend = result.returncode == 0
            if not paused_backend and "Could not find specified service" not in result.stderr:
                raise RuntimeError(f"无法暂停 Mac USB 后台：{result.stderr.strip()}")
            time.sleep(2)

        probe = load_probe_module()
        transport = DeployTransport(probe)
        transport.open()
        try:
            transport.push(script.encode("utf-8"), script_path, 0o755)
            transport.shell(
                f"rm -f {shlex.quote(log_path)}; "
                f"start-stop-daemon -S -b -x {shlex.quote(script_path)}; "
                "sleep 0.3; "
                f"grep -q __LAUNCHED__ {shlex.quote(log_path)}"
            )
        finally:
            transport.close()

        # USB 会短暂消失；用全新 ADB 连接轮询恢复，避免复用失效句柄。
        time.sleep(5)
        last_error: Exception | None = None
        for _ in range(20):
            check = DeployTransport(probe)
            try:
                check.open()
                print(
                    check.shell(
                        f"test -s {shlex.quote(log_path)} && "
                        f"grep -q __RESTORE__ {shlex.quote(log_path)} && "
                        f"{{ cat {shlex.quote(log_path)}; "
                        "echo __RECOVERY_STATE__; "
                        "cat /sys/devices/virtual/android_usb/android0/enable; "
                        "pidof ql_manager_server; "
                        f"rm -f {shlex.quote(log_path)} {shlex.quote(script_path)}; }}"
                    )
                )
                return
            except Exception as error:
                last_error = error
                time.sleep(1)
            finally:
                try:
                    check.close()
                except Exception:
                    pass
        raise RuntimeError(f"USB gadget 恢复后仍无法重新连接 ADB：{last_error}")
    finally:
        if paused_backend:
            subprocess.run(
                ["launchctl", "bootstrap", launch_domain, str(launch_plist)],
                capture_output=True,
            )
            subprocess.run(
                ["launchctl", "kickstart", "-k", launch_label],
                capture_output=True,
            )
            # LaunchAgent 配置了 5 秒节流，给后台足够时间重新监听。
            time.sleep(6)


def inspect_kernel_build() -> None:
    """只读检查内核配置、构建目录与 DATA11 桥所需导出符号。"""
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        print(
            transport.shell(
                "echo __KERNEL_FILES__; "
                "uname -a; "
                "ls -ld /proc/config.gz /lib/modules /lib/modules/3.18.44 /usr/src 2>&1 || true; "
                "find /lib/modules/3.18.44 -type f -name '*.ko' -maxdepth 4 2>/dev/null | head -40; "
                "echo __DATA11_RECOVERY__; "
                "cat /sys/devices/virtual/android_usb/android0/enable; "
                "cat /sys/devices/virtual/android_usb/android0/functions; "
                "pidof ql_manager_server; "
                "grep '^qdc507_data11_bridge ' /proc/modules || true; "
                "ls -l /dev/djonehub_data11 2>/dev/null || true; "
                "test -s /data/local/tmp/djonehub-data11-test.log && "
                "  tail -120 /data/local/tmp/djonehub-data11-test.log || true; "
                "echo __CONFIG__; "
                "zcat /proc/config.gz 2>/dev/null | "
                "  grep -E 'CONFIG_(MODULES|MODVERSIONS|MODULE_UNLOAD|PREEMPT|ARM|SMP|AEABI|SMD|DEBUG_FS|DEBUG_SPINLOCK|UACCESS_WITH_MEMCPY|CPU_USE_DOMAINS)(=| )' || true; "
                "echo __EXPORTED_SYMBOLS__; "
                "grep -E ' (smd_named_open_on_edge|smd_open|smd_close|smd_read|smd_read_avail|smd_write|smd_write_avail|alloc_chrdev_region|cdev_add|class_create|device_create)$' "
                "  /proc/kallsyms 2>/dev/null || true"
            )
        )
    finally:
        transport.close()


def pull_kernel_config() -> None:
    """把实机 /proc/config.gz 拉到本地临时目录，供 ABI 一致构建使用。"""
    target = Path("/private/tmp/djonehub-runtime-config.gz")
    reference_target = Path("/private/tmp/djonehub-runtime-ansi_cprng.ko")
    reference_remote = "/lib/modules/3.18.44/kernel/crypto/ansi_cprng.ko"
    launch_domain = f"gui/{os.getuid()}"
    launch_label = f"{launch_domain}/com.jamie.djonehub"
    launch_plist = Path.home() / "Library/LaunchAgents/com.jamie.djonehub.plist"
    paused_backend = False

    try:
        if launch_plist.is_file():
            result = subprocess.run(
                ["launchctl", "bootout", launch_label],
                capture_output=True,
                text=True,
            )
            paused_backend = result.returncode == 0
            if not paused_backend and "Could not find specified service" not in result.stderr:
                raise RuntimeError(f"无法暂停 Mac USB 后台：{result.stderr.strip()}")
            time.sleep(2)

        probe = load_probe_module()
        transport = DeployTransport(probe)
        transport.open()
        try:
            payload = transport.pull("/proc/config.gz")
            reference_payload = transport.pull(reference_remote)
        finally:
            transport.close()
        if not payload.startswith(b"\x1f\x8b"):
            raise RuntimeError("设备返回的 /proc/config.gz 不是有效 gzip 数据")
        # 这是 ADB 文件传输结果，不是手工编辑源文件。
        target.write_bytes(payload)
        reference_target.write_bytes(reference_payload)
        print(f"已读取实机配置：{target}（{len(payload)} 字节）")
        print(
            f"已读取原厂 ABI 参考模块：{reference_target}（{len(reference_payload)} 字节）"
        )
    finally:
        if paused_backend:
            subprocess.run(
                ["launchctl", "bootstrap", launch_domain, str(launch_plist)],
                capture_output=True,
            )
            subprocess.run(
                ["launchctl", "kickstart", "-k", launch_label],
                capture_output=True,
            )
            time.sleep(6)


def probe_data11_module_load() -> None:
    """只验证 DATA11 桥可加载，不打开通道、不重绑 USB。"""
    if not DATA11_BRIDGE_PATH.is_file():
        raise RuntimeError(f"找不到已编译的桥模块：{DATA11_BRIDGE_PATH}")

    launch_domain = f"gui/{os.getuid()}"
    launch_label = f"{launch_domain}/com.jamie.djonehub"
    launch_plist = Path.home() / "Library/LaunchAgents/com.jamie.djonehub.plist"
    remote_path = "/data/local/tmp/qdc507_data11_bridge.ko"
    paused_backend = False

    try:
        if launch_plist.is_file():
            result = subprocess.run(
                ["launchctl", "bootout", launch_label],
                capture_output=True,
                text=True,
            )
            paused_backend = result.returncode == 0
            if not paused_backend and "Could not find specified service" not in result.stderr:
                raise RuntimeError(f"无法暂停 Mac USB 后台：{result.stderr.strip()}")
            time.sleep(2)

        probe = load_probe_module()
        transport = DeployTransport(probe)
        transport.open()
        try:
            transport.push(DATA11_BRIDGE_PATH.read_bytes(), remote_path, 0o600)
            print(
                transport.shell(
                    f"module={shlex.quote(remote_path)}; load_ok=0; "
                    "cleanup() { rmmod qdc507_data11_bridge 2>/dev/null || true; "
                    "rm -f \"$module\"; }; "
                    "trap cleanup 0 1 2 3 15; "
                    "before=$(pidof ql_manager_server); test -n \"$before\"; "
                    "echo __BEFORE__; echo ql_manager_server=$before; "
                    "cat /sys/devices/virtual/android_usb/android0/enable; "
                    "insmod \"$module\" && load_ok=1; "
                    "if test \"$load_ok\" -eq 1; then "
                    "  echo __LOADED__; "
                    "  grep '^qdc507_data11_bridge ' /proc/modules; "
                    "  echo __MISC__; grep -E 'djonehub|data11' /proc/misc || true; "
                    "  echo __DMESG__; dmesg | tail -20; "
                    "  minor=$(awk '$2 == \"djonehub_data11\" { print $1 }' /proc/misc); "
                    "  if test -n \"$minor\"; then "
                    "    rm -f /dev/djonehub_data11; "
                    "    mknod /dev/djonehub_data11 c 10 \"$minor\"; "
                    "    chmod 600 /dev/djonehub_data11; "
                    "    ls -l /dev/djonehub_data11; "
                    "    after=$(pidof ql_manager_server); test \"$after\" = \"$before\"; "
                    "    rmmod qdc507_data11_bridge; "
                    "    rm -f /dev/djonehub_data11; "
                    "    echo __UNLOADED__; "
                    "    ! grep -q '^qdc507_data11_bridge ' /proc/modules; "
                    "    echo ql_manager_server=$after; "
                    "    cat /sys/devices/virtual/android_usb/android0/enable; "
                    "  else load_ok=0; fi; "
                    "else "
                    "  echo __LOAD_ERROR__; dmesg | tail -80; "
                    "fi; "
                    "test \"$load_ok\" -eq 1"
                )
            )
        finally:
            try:
                transport.close()
            except Exception:
                pass
    finally:
        if paused_backend:
            subprocess.run(
                ["launchctl", "bootstrap", launch_domain, str(launch_plist)],
                capture_output=True,
            )
            subprocess.run(
                ["launchctl", "kickstart", "-k", launch_label],
                capture_output=True,
            )
            time.sleep(6)


def require_wifi_default_route() -> None:
    """USB 重绑定前强制要求默认出口是 Wi-Fi，避免当前任务随 ECM 断开。"""
    result = subprocess.run(
        ["route", "-n", "get", "default"],
        capture_output=True,
        text=True,
        check=True,
    )
    match = re.search(r"^\s*interface:\s*(\S+)\s*$", result.stdout, re.MULTILINE)
    if match is None or match.group(1) != "en0":
        actual = match.group(1) if match else "未知"
        raise RuntimeError(
            f"网络保护闸拒绝 USB 重绑定：默认出口是 {actual}，必须先切到 Wi-Fi en0"
        )


def probe_data11_bridge() -> None:
    """临时释放 USB serial，验证 DATA11 的 AT 与 eUICC 2 通道后完整恢复。"""
    require_wifi_default_route()
    if not DATA11_BRIDGE_PATH.is_file():
        raise RuntimeError(f"找不到已编译的桥模块：{DATA11_BRIDGE_PATH}")

    launch_domain = f"gui/{os.getuid()}"
    launch_label = f"{launch_domain}/com.jamie.djonehub"
    launch_plist = Path.home() / "Library/LaunchAgents/com.jamie.djonehub.plist"
    remote_module = "/data/local/tmp/qdc507_data11_bridge.ko"
    remote_agent = "/data/local/tmp/qdc507-agent-data11-test"
    remote_script = "/data/local/tmp/djonehub-data11-test.sh"
    remote_log = "/data/local/tmp/djonehub-data11-test.log"
    remote_agent_log = "/data/local/tmp/djonehub-data11-agent.log"
    script = f"""#!/bin/sh
# DATA11 临时验证。任何退出路径都恢复 USB gadget，绝不停止原厂服务。
enable=/sys/devices/virtual/android_usb/android0/enable
functions=/sys/devices/virtual/android_usb/android0/functions
transports=/sys/devices/virtual/android_usb/android0/f_serial/transports
module={remote_module}
agent={remote_agent}
node=/dev/djonehub_data11
log={remote_log}
agent_log={remote_agent_log}
original_functions=$(cat "$functions")
original_transports=$(cat "$transports")
before_pid=$(pidof ql_manager_server)
agent_pid=
restored=0

exec >"$log" 2>&1
echo __LAUNCHED__

restore() {{
    test "$restored" -eq 0 || return 0
    restored=1
    if test -n "$agent_pid"; then
        kill -TERM "$agent_pid" 2>/dev/null || true
        wait "$agent_pid" 2>/dev/null || true
        agent_pid=
    fi
    rm -f "$node"
    rmmod qdc507_data11_bridge 2>/dev/null || true
    echo 0 >"$enable" 2>/dev/null || true
    echo "$original_transports" >"$transports" 2>/dev/null || true
    echo "$original_functions" >"$functions" 2>/dev/null || true
    echo 1 >"$enable" 2>/dev/null || true
    echo __RESTORED__
}}
trap restore 0 1 2 3 15

test -n "$before_pid"
echo __BEFORE__
echo ql_manager_server="$before_pid"
echo functions="$original_functions"
echo transports="$original_transports"
cat "$enable"

# 只移除 serial，保留 diag、ecm、ffs、audio 的原始顺序和配置。
detached_functions=$(echo "$original_functions" | sed 's/^serial,//; s/,serial,/,/; s/,serial$//; s/^serial$//')
echo 0 >"$enable"
sleep 1
echo tty >"$transports"
echo "$detached_functions" >"$functions"
# 修改 composition 后必须重新启用 gadget，否则 ECM 虽在 functions 列表中，
# Mac/iPad 仍看不到网络接口，模块本机健康检查会产生“假通过”。
echo 1 >"$enable"
sleep 2

echo __DETACHED__
echo enabled=$(cat "$enable")
echo functions=$(cat "$functions")
grep -E '\\|DATA11[ |]' /sys/kernel/debug/smd/ch 2>/dev/null || true

insmod "$module"
minor=$(awk '$2 == "djonehub_data11" {{ print $1 }}' /proc/misc)
test -n "$minor"
test -e "$node" || mknod "$node" c 10 "$minor"
chmod 600 "$node"

echo __AT_TEST__
(
    exec 9<>"$node"
    printf 'AT\r' >&9
    sleep 1
    dd bs=512 count=1 <&9 2>/dev/null
    printf 'AT+CCHO="A06573746B6D65FFFF4953442D522031"\r' >&9
    sleep 1
    dd bs=512 count=1 <&9 2>/dev/null
    exec 9>&-
    exec 9<&-
) &
client_pid=$!
seconds=0
while kill -0 "$client_pid" 2>/dev/null && test "$seconds" -lt 12; do
    sleep 1
    seconds=$((seconds+1))
done
if kill -0 "$client_pid" 2>/dev/null; then
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    echo AT_TEST_TIMEOUT
else
    wait "$client_pid"
fi

echo __AGENT_TEST__
rm -f "$agent_log"
"$agent" >"$agent_log" 2>&1 &
agent_pid=$!
sleep 10
kill -0 "$agent_pid"
wget -q -T 8 -O - http://127.0.0.1:7575/api/health
echo
kill -TERM "$agent_pid"
wait "$agent_pid" 2>/dev/null || true
agent_pid=
echo __AGENT_LOG__
tail -80 "$agent_log"

restore
sleep 2
after_pid=$(pidof ql_manager_server)
echo __AFTER__
echo ql_manager_server="$after_pid"
cat "$enable"
test "$after_pid" = "$before_pid"
sync
"""

    paused_backend = False
    try:
        if launch_plist.is_file():
            result = subprocess.run(
                ["launchctl", "bootout", launch_label],
                capture_output=True,
                text=True,
            )
            paused_backend = result.returncode == 0
            if not paused_backend and "Could not find specified service" not in result.stderr:
                raise RuntimeError(f"无法暂停 Mac USB 后台：{result.stderr.strip()}")
            time.sleep(2)

        probe = load_probe_module()
        transport = DeployTransport(probe)
        transport.open()
        try:
            transport.push(DATA11_BRIDGE_PATH.read_bytes(), remote_module, 0o600)
            transport.push(AGENT_PATH.read_bytes(), remote_agent, 0o755)
            transport.push(script.encode("utf-8"), remote_script, 0o755)
            try:
                transport.shell(
                    f"rm -f {shlex.quote(remote_log)}; "
                    f"start-stop-daemon -S -b -x {shlex.quote(remote_script)}; "
                    "sleep 0.3; "
                    f"grep -q __LAUNCHED__ {shlex.quote(remote_log)}"
                )
            except Exception as error:
                # gadget 解除得比 ADB 状态帧更快时连接会消失，后续恢复轮询负责判定结果。
                print(f"ADB 启动确认已断开，继续等待自动恢复：{error}")
        finally:
            transport.close()

        # gadget 恢复后建立全新的 ADB 会话读取结果，不复用已经失效的句柄。
        time.sleep(8)
        last_error: Exception | None = None
        for _ in range(25):
            check = DeployTransport(probe)
            try:
                check.open()
                output = check.shell(
                    f"test -s {shlex.quote(remote_log)} && "
                    f"grep -q __RESTORED__ {shlex.quote(remote_log)} && "
                    f"{{ cat {shlex.quote(remote_log)}; "
                    "echo __RECOVERY_STATE__; "
                    "cat /sys/devices/virtual/android_usb/android0/enable; "
                    "pidof ql_manager_server; "
                    f"rm -f {shlex.quote(remote_log)} {shlex.quote(remote_script)} "
                    f"{shlex.quote(remote_module)} {shlex.quote(remote_agent)} "
                    f"{shlex.quote(remote_agent_log)}; }}"
                )
                print(output)
                return
            except Exception as error:
                last_error = error
                time.sleep(1)
            finally:
                try:
                    check.close()
                except Exception:
                    pass
        raise RuntimeError(f"USB gadget 恢复后仍无法读取 DATA11 测试结果：{last_error}")
    finally:
        if paused_backend:
            subprocess.run(
                ["launchctl", "bootstrap", launch_domain, str(launch_plist)],
                capture_output=True,
            )
            subprocess.run(
                ["launchctl", "kickstart", "-k", launch_label],
                capture_output=True,
            )
            time.sleep(6)


def diagnose_agent_start() -> None:
    """保留旧命令名，但永久拒绝任何会停止原厂服务的诊断。"""
    raise RuntimeError("该诊断已永久移除：禁止停止 ql_manager_server")


def diagnose_esim_read() -> None:
    """保留旧命令名，但永久拒绝任何会停止原厂服务的 eSIM 诊断。"""
    raise RuntimeError("该诊断已永久移除：禁止停止 ql_manager_server")


def run_compatibility_probes() -> None:
    """逐个运行纯 Go 探针；不停止原厂服务，不触碰 AT 或数据连接。"""
    candidates = [
        MODULE_DIRECTORY / f"compat-go{version}-arm{arm}"
        for version in ("126", "123")
        for arm in (5, 6, 7)
    ]
    for path in candidates:
        if not path.is_file():
            raise RuntimeError(f"缺少兼容探针：{path}")
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    try:
        for path in candidates:
            remote = "/data/local/tmp/djonehub-compat-probe"
            transport.push(path.read_bytes(), remote, 0o755)
            result = transport.shell(
                # 不在内部 shell 主动 exit，否则会提前关闭 ADB 流，外层随机状态标记无法返回。
                f"set +e; '{remote}' 2>&1; code=$?; rm -f '{remote}'; echo exit=$code"
            )
            print(f"{path.name}: {result.replace(chr(13), '').strip()}")
    finally:
        transport.close()


def run_startup_probes() -> None:
    """运行完整代理的只读启动阶段；不发送 AT 指令，也不停止原厂服务。"""
    if not AGENT_PATH.is_file():
        raise RuntimeError(f"缺少代理程序：{AGENT_PATH}")
    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    remote = "/data/local/tmp/qdc507-agent-startup-probe"
    try:
        transport.push(AGENT_PATH.read_bytes(), remote, 0o755)
        for stage in ("runtime", "routes", "listen", "at-open"):
            result = transport.shell(
                f"set +e; timeout -t 5 '{remote}' --startup-probe '{stage}' 2>&1; "
                f"code=$?; echo exit=$code"
            )
            print(f"{stage}: {result.replace(chr(13), '').strip()}")
    finally:
        try:
            transport.shell(f"rm -f '{remote}'")
        finally:
            transport.close()


def run_agent_matrix() -> None:
    """验证所有 Go/GOARM 完整代理候选，避免用小探针替代真实启动兼容性。"""
    candidates = [
        MODULE_DIRECTORY / f"qdc507-agent-go{version}-arm{arm}"
        for version in ("123", "126")
        for arm in (5, 6, 7)
    ]
    # Go 1.24 仅需验证模块实际使用的 ARMv7；它是新版 LPA 依赖允许的最低版本。
    candidates.insert(3, MODULE_DIRECTORY / "qdc507-agent-go124-arm7")
    for path in candidates:
        if not path.is_file():
            raise RuntimeError(f"缺少完整代理候选：{path}")

    probe = load_probe_module()
    transport = DeployTransport(probe)
    transport.open()
    remote = "/data/local/tmp/qdc507-agent-matrix"
    try:
        for path in candidates:
            transport.push(path.read_bytes(), remote, 0o755)
            stage_results = []
            for stage in ("runtime", "routes", "listen", "at-open"):
                result = transport.shell(
                    f"set +e; timeout -t 5 '{remote}' --startup-probe '{stage}' 2>&1; "
                    f"code=$?; echo exit=$code"
                )
                normalized = result.replace("\r", "").strip().replace("\n", " | ")
                stage_results.append(f"{stage}=[{normalized}]")
            print(f"{path.name}: {' '.join(stage_results)}")
    finally:
        try:
            transport.shell(f"rm -f '{remote}'")
        finally:
            transport.close()


def main() -> int:
    action = sys.argv[1:]
    if action not in (
        ["--confirm-persistent-deploy"],
        ["--confirm-runtime-update"],
        ["--update-startup-hook"],
        ["--inspect-startup-hooks"],
        ["--inspect-mobile-start-failure"],
        ["--inspect-startup-result"],
        ["--start-mobile-now"],
        ["--inspect-at-channels"],
        ["--inspect-vendor-ipc"],
        ["--inspect-qmi-console"],
        ["--probe-qmi-logical-channel"],
        ["--inspect-modem-routing"],
        ["--correlate-usb-at-channel"],
        ["--print-smd-data"],
        ["--probe-smd21-open"],
        ["--probe-smd21-detached"],
        ["--inspect-kernel-build"],
        ["--pull-kernel-config"],
        ["--probe-data11-module-load"],
        ["--probe-data11-bridge"],
        ["--diagnose-agent-start"],
        ["--diagnose-esim-read"],
        ["--run-compatibility-probes"],
        ["--run-startup-probes"],
        ["--run-agent-matrix"],
    ):
        print(
            f"用法：{Path(sys.argv[0]).name} --confirm-persistent-deploy|--confirm-runtime-update|--update-startup-hook|--inspect-startup-hooks|--inspect-mobile-start-failure|--inspect-startup-result|--start-mobile-now|--inspect-at-channels|--inspect-vendor-ipc|--inspect-qmi-console|--probe-qmi-logical-channel|--inspect-modem-routing|--correlate-usb-at-channel|--inspect-kernel-build|--pull-kernel-config|--probe-data11-module-load|--probe-data11-bridge|--diagnose-agent-start|--diagnose-esim-read|--run-compatibility-probes|--run-startup-probes|--run-agent-matrix",
            file=sys.stderr,
        )
        return 64
    try:
        if action == ["--confirm-runtime-update"]:
            update_installed_runtime()
        elif action == ["--update-startup-hook"]:
            update_startup_hook()
        elif action == ["--inspect-startup-hooks"]:
            inspect_startup_hooks()
        elif action == ["--inspect-mobile-start-failure"]:
            inspect_mobile_start_failure()
        elif action == ["--inspect-startup-result"]:
            inspect_startup_result()
        elif action == ["--start-mobile-now"]:
            start_mobile_now()
        elif action == ["--inspect-at-channels"]:
            inspect_at_channels()
        elif action == ["--inspect-vendor-ipc"]:
            inspect_vendor_ipc()
        elif action == ["--inspect-qmi-console"]:
            inspect_qmi_console()
        elif action == ["--probe-qmi-logical-channel"]:
            probe_qmi_logical_channel()
        elif action == ["--inspect-modem-routing"]:
            inspect_modem_routing()
        elif action == ["--correlate-usb-at-channel"]:
            correlate_usb_at_channel()
        elif action == ["--print-smd-data"]:
            print_smd_data()
        elif action == ["--probe-smd21-open"]:
            probe_smd21_open()
        elif action == ["--probe-smd21-detached"]:
            probe_smd21_detached()
        elif action == ["--inspect-kernel-build"]:
            inspect_kernel_build()
        elif action == ["--pull-kernel-config"]:
            pull_kernel_config()
        elif action == ["--probe-data11-module-load"]:
            probe_data11_module_load()
        elif action == ["--probe-data11-bridge"]:
            probe_data11_bridge()
        elif action == ["--diagnose-agent-start"]:
            diagnose_agent_start()
        elif action == ["--diagnose-esim-read"]:
            diagnose_esim_read()
        elif action == ["--run-compatibility-probes"]:
            run_compatibility_probes()
        elif action == ["--run-startup-probes"]:
            run_startup_probes()
        elif action == ["--run-agent-matrix"]:
            run_agent_matrix()
        else:
            deploy()
        return 0
    except Exception as error:
        print(f"部署失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
