#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
AAPT2=${AAPT2:-$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2}
APK=${1:-$ROOT/build/android/AirSIM-Phone-Bridge-debug.apk}

permissions=$($AAPT2 dump permissions "$APK")
manifest=$($AAPT2 dump xmltree --file AndroidManifest.xml "$APK")

case "$permissions" in
  *moe.shizuku.manager.permission.API_V23*) ;;
  *) echo "FAIL: Shizuku API permission missing from APK" >&2; exit 1 ;;
esac
case "$manifest" in
  *moe.shizuku.client.V3_SUPPORT*) ;;
  *) echo "FAIL: Shizuku V3 client marker missing from APK" >&2; exit 1 ;;
esac
case "$manifest" in
  *com.airsim.phonecontrol.shizuku*) ;;
  *) echo "FAIL: Shizuku provider authority missing from APK" >&2; exit 1 ;;
esac

echo "APK Shizuku integration verified"
