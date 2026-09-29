#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ADB=${ADB:-adb}
DEVICE=${DEVICE:-${ADB_SERIAL:-}}
APK="$ROOT/build/android/AirSIM-Phone-Bridge-debug.apk"

if [ -z "$DEVICE" ]; then
  echo "Set DEVICE or ADB_SERIAL to the exact Samsung device before installing" >&2
  exit 2
fi

if [ ! -f "$APK" ]; then
  "$ROOT/build.sh"
fi
"$ADB" connect "$DEVICE" >/dev/null
"$ADB" -s "$DEVICE" install -r "$APK"
"$ADB" -s "$DEVICE" shell am start -n com.airsim.phonecontrol/.MainActivity
