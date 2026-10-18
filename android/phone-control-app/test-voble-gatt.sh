#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/voble-gatt-tests"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
mkdir -p "$OUT"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$ROOT/build/jvm-test:$SDK/platforms/android-35/android.jar" -d "$OUT" \
  "$ROOT"/test/voble-gatt/android/bluetooth/*.java \
  "$ROOT"/test/voble-gatt/android/bluetooth/le/*.java \
  "$ROOT"/test/voble-gatt/android/os/*.java \
  "$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEGattServer.java \
  "$ROOT"/test/com/airsim/phonecontrol/VoBLEGattLifecycleTests.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ROOT/build/jvm-test:$SDK/platforms/android-35/android.jar" \
  com.airsim.phonecontrol.VoBLEGattLifecycleTests
