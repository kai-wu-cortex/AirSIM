#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE="$ROOT/build/jvm-test"
OUT="$BASE/audio-policy"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
mkdir -p "$OUT"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$BASE:$ANDROID_JAR" -d "$OUT" \
  "$ROOT"/test/android/telecom/Call.java \
  "$ROOT"/test/com/airsim/phonecontrol/AppConfig.java \
  "$ROOT"/test/audio-policy/android/os/Handler.java \
  "$ROOT"/test/audio-policy/android/telecom/InCallService.java \
  "$ROOT"/test/audio-policy/com/airsim/phonecontrol/*.java \
  "$ROOT"/test/audio-policy/com/airsim/phonecontrol/voble/VoBLEGatewayService.java \
  "$ROOT"/src/com/airsim/phonecontrol/TelecomStateMapper.java \
  "$ROOT"/src/com/airsim/phonecontrol/LocalOutputMuteController.java \
  "$ROOT"/src/com/airsim/phonecontrol/LocalCallAudioController.java \
  "$ROOT"/src/com/airsim/phonecontrol/RemoteAudioSessionRegistry.java \
  "$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEMediaSession.java \
  "$ROOT"/src/com/airsim/phonecontrol/AirSIMInCallService.java \
  "$ROOT"/test/com/airsim/phonecontrol/RemoteCallMuteLifecycleTests.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$BASE:$ANDROID_JAR" com.airsim.phonecontrol.RemoteCallMuteLifecycleTests
