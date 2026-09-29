#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ADB=${ADB:-adb}
ADB_SERIAL=${ADB_SERIAL:-}
LISTEN_HOST=${LISTEN_HOST:-}
LISTEN_INTERFACE=${LISTEN_INTERFACE:-avf_tap_fixed}
LISTEN_PORT=${LISTEN_PORT:-7580}
REMOTE_DIR=/data/local/tmp/airsim-phone-audio-bridge
REMOTE_JAR=$REMOTE_DIR/airsim-phone-audio-bridge.jar
REMOTE_PID=$REMOTE_DIR/bridge.pid
REMOTE_LOG=$REMOTE_DIR/bridge.jsonl
LOCAL_JAR=$SCRIPT_DIR/build/airsim-phone-audio-bridge.jar

usage() {
    echo "usage: ADB_SERIAL=serial [LISTEN_HOST=private-ip|LISTEN_INTERFACE=avf_tap_fixed] $0 {start|status|logs|stop}" >&2
    exit 2
}

adb_command() {
    if [ -n "$ADB_SERIAL" ]; then
        "$ADB" -s "$ADB_SERIAL" "$@"
    else
        "$ADB" "$@"
    fi
}

validate_port() {
    case "$LISTEN_PORT" in
        ''|*[!0-9]*) echo "invalid LISTEN_PORT" >&2; exit 2 ;;
    esac
    if [ "$LISTEN_PORT" -lt 1024 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
        echo "LISTEN_PORT must be 1024..65535" >&2
        exit 2
    fi
}

validate_interface() {
    if [ -z "$LISTEN_HOST" ]; then
        if [ "$LISTEN_INTERFACE" != "avf_tap_fixed" ]; then
            echo "LISTEN_INTERFACE must be avf_tap_fixed" >&2
            exit 2
        fi
        interface_host=$(adb_command shell ip -o -4 addr show dev "$LISTEN_INTERFACE" | awk 'NR == 1 { split($4, fields, "/"); print fields[1] }')
        if [ -z "$interface_host" ]; then
            echo "LISTEN_INTERFACE has no private IPv4 address" >&2
            exit 2
        fi
        printf 'validated_interface=%s current_host=%s\n' "$LISTEN_INTERFACE" "$interface_host"
        return
    fi
    case "$LISTEN_HOST" in
        ''|*[!0-9.]*) echo "LISTEN_HOST must be an explicit IPv4 address" >&2; exit 2 ;;
        0.0.0.0) echo "wildcard listening is forbidden" >&2; exit 2 ;;
    esac
    interface=$(adb_command shell ip -o -4 addr show | awk -v host="$LISTEN_HOST" '
        {
            address=$4
            sub("/.*", "", address)
            if (address == host) { print $2; exit }
        }
    ')
    if [ -z "$interface" ]; then
        echo "LISTEN_HOST is not assigned on the Android device" >&2
        exit 2
    fi
    case "$interface" in
        lo|avf*|vmtap*|veth*|tap*|virt*) ;;
        wlan*|swlan*|rmnet*|rndis*|usb*|ap*|bt-pan*|tether*)
            echo "refusing externally reachable Android interface: $interface" >&2
            exit 2
            ;;
        *)
            echo "interface is not recognized as AVF-private: $interface" >&2
            exit 2
            ;;
    esac
    printf 'validated_interface=%s\n' "$interface"
}

is_running() {
    adb_command shell "test -r '$REMOTE_PID' && pid=\$(cat '$REMOTE_PID') && kill -0 \"\$pid\" 2>/dev/null"
}

start_bridge() {
    validate_port
    validate_interface
    if is_running; then
        echo "bridge already running"
        exit 0
    fi
    "$SCRIPT_DIR/build.sh"
    adb_command shell "mkdir -p '$REMOTE_DIR'"
    adb_command push "$LOCAL_JAR" "$REMOTE_JAR" >/dev/null
    if [ -n "$LISTEN_HOST" ]; then
        listen_option="--listen-host '$LISTEN_HOST'"
    else
        listen_option="--listen-interface '$LISTEN_INTERFACE'"
    fi
    adb_command shell "chmod 600 '$REMOTE_JAR'; rm -f '$REMOTE_LOG' '$REMOTE_PID'; nohup env CLASSPATH='$REMOTE_JAR' app_process /system/bin com.airsim.bridge.PhoneAudioBridge $listen_option --listen-port '$LISTEN_PORT' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'$REMOTE_PID'"
    sleep 1
    if ! is_running; then
        adb_command shell "tail -n 80 '$REMOTE_LOG'" >&2 || true
        echo "bridge failed to stay running" >&2
        exit 1
    fi
    adb_command shell "tail -n 20 '$REMOTE_LOG'"
}

stop_bridge() {
    if ! adb_command shell "test -r '$REMOTE_PID'"; then
        echo "bridge is not running"
        exit 0
    fi
    adb_command shell "pid=\$(cat '$REMOTE_PID'); kill \"\$pid\" 2>/dev/null || true; rm -f '$REMOTE_PID'"
    echo "bridge stopped"
}

action=${1:-}
case "$action" in
    start) start_bridge ;;
    status)
        if is_running; then
            echo "bridge running"
            adb_command shell "tail -n 20 '$REMOTE_LOG'"
        else
            echo "bridge stopped"
            exit 1
        fi
        ;;
    logs) adb_command shell "tail -n 200 '$REMOTE_LOG'" ;;
    stop) stop_bridge ;;
    *) usage ;;
esac
