#!/bin/sh
set -eu

ADB=${ADB:-adb}
ADB_SERIAL=${ADB_SERIAL:-}

adb_command() {
  if [ -n "$ADB_SERIAL" ]; then "$ADB" -s "$ADB_SERIAL" "$@"; else "$ADB" "$@"; fi
}

stream_muted() {
  adb_command shell dumpsys audio \
    | sed -n '/^- STREAM_VOICE_CALL:/,/^- STREAM_SYSTEM:/p' \
    | awk '/Muted:/ { print $2; exit }'
}

before=$(stream_muted)
restore() {
  if [ "$before" = "true" ]; then
    adb_command shell cmd audio adj-mute 0 >/dev/null
  else
    adb_command shell cmd audio adj-unmute 0 >/dev/null
  fi
}
trap restore EXIT INT TERM

adb_command shell am broadcast \
  -a com.airsim.phonecontrol.DEBUG_SET_LOCAL_OUTPUT \
  -n com.airsim.phonecontrol/.DebugCommandReceiver \
  --ez muted true >/dev/null
sleep 1
[ "$(stream_muted)" = "true" ] || { echo "FAIL: Shizuku mute was not applied" >&2; exit 1; }

adb_command shell am broadcast \
  -a com.airsim.phonecontrol.DEBUG_SET_LOCAL_OUTPUT \
  -n com.airsim.phonecontrol/.DebugCommandReceiver \
  --ez muted false >/dev/null
sleep 1
[ "$(stream_muted)" = "false" ] || { echo "FAIL: Shizuku mute was not restored" >&2; exit 1; }

echo "device Shizuku mute integration passed"
