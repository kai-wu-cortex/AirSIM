#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADB="/opt/homebrew/bin/adb"
F50_IP="${1:-192.168.0.1:5555}"

echo "=== [1/5] 检查并安装 Android SDK 构建工具与 scrcpy 投屏工具 ==="
if [ ! -d "/opt/homebrew/share/android-commandlinetools" ]; then
    brew install --cask android-commandlinetools
fi
if ! command -v scrcpy >/dev/null 2>&1; then
    brew install scrcpy
fi

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
SDKMANAGER="/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"

if [ ! -f "$ANDROID_SDK_ROOT/platforms/android-35/android.jar" ] || [ ! -f "$ANDROID_SDK_ROOT/build-tools/35.0.0/d8" ]; then
    echo "正在通过 sdkmanager 安装 Android 35 SDK 与 Build-Tools 35.0.0..."
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "platforms;android-35" "build-tools;35.0.0" >/dev/null || true
fi

echo "=== [2/5] 编译适配 F50 Pro (MU3356) 的 AirSIM 通话音频桥与 Standalone APK ==="
"$SCRIPT_DIR/android/phone-audio-bridge/build.sh"
APK_PATH=$("$SCRIPT_DIR/android-standalone/build.sh" | tail -n 1)
echo "编译完成: $APK_PATH"

echo "=== [3/5] 连接中兴 F50 Pro ($F50_IP) 并安装 AirSIM ==="
"$ADB" connect "$F50_IP"
"$ADB" -s "$F50_IP" wait-for-device

# 安装并自动授予全部运行时权限 (-g)
"$ADB" -s "$F50_IP" install -r -g "$APK_PATH"

# 设为系统默认电话应用 (Telecom set-default-dialer)，并允许后台常驻
"$ADB" -s "$F50_IP" shell "cmd telecom set-default-dialer com.airsim.phonecontrol.standalone"
"$ADB" -s "$F50_IP" shell "dumpsys deviceidle whitelist +com.airsim.phonecontrol.standalone" >/dev/null 2>&1 || true
"$ADB" -s "$F50_IP" shell "appops set com.airsim.phonecontrol.standalone PROJECT_MEDIA allow" >/dev/null 2>&1 || true

echo "=== [4/5] 启动 F50 Pro 特权音频桥守护进程 (RootBridgeMain @ 127.0.0.1:27580) ==="
"$ADB" -s "$F50_IP" shell "cmd power wakeup; svc power stayon true; wm dismiss-keyguard"
"$ADB" -s "$F50_IP" shell '
killall airsim-root-bridge 2>/dev/null || true
APK_PATH=$(pm path com.airsim.phonecontrol.standalone | sed "s/^package://")
TOKEN=$(cat /proc/sys/kernel/random/uuid | tr -d "-")
printf "%s" "$TOKEN" > /data/local/tmp/airsim-bridge.token
chmod 644 /data/local/tmp/airsim-bridge.token
CLASSPATH="$APK_PATH" setsid app_process /system/bin --nice-name=airsim-root-bridge com.airsim.phonecontrol.RootBridgeMain com.airsim.phonecontrol.standalone 27580 /data/local/tmp/airsim-bridge.token >/data/local/tmp/airsim-bridge.log 2>&1 </dev/null &
'
sleep 1

echo "=== [5/5] 启动 AirSIM 后台网关服务并生成 iPhone VoWLAN 局域网配对码 ==="
"$ADB" -s "$F50_IP" shell "run-as com.airsim.phonecontrol.standalone touch files/request-pairing.flag" 2>/dev/null || true
sleep 6
echo ""
echo "✅ AirSIM 已在中兴 F50 Pro 上作为常驻服务启动并就绪！"
echo "--------------------------------------------------------"
"$ADB" -s "$F50_IP" shell "run-as com.airsim.phonecontrol.standalone cat files/pairing-session.txt" 2>/dev/null || true
echo "--------------------------------------------------------"
echo "📱 请将 iPhone 连接到 F50 Pro 的 Wi-Fi 热点，在 iPhone 端 AirSIM 中输入上方 6 位配对码（或手动填入上方 192.168.0.1:端口）即可完成配对！"
