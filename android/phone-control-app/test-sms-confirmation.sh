#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test/sms-confirmation"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
ANDROID_JAR="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platforms/android-35/android.jar"
mkdir -p "$OUT"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$ANDROID_JAR:$ROOT/build/jvm-test/sms-compat:$ROOT/build/jvm-test" -d "$OUT" \
  "$ROOT/src/com/airsim/phonecontrol/PrivilegedSmsConfirmation.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSConfirmation.java" \
  "$ROOT/src/com/airsim/phonecontrol/RootSMSCallbackProvider.java" \
  "$ROOT/src/com/airsim/phonecontrol/RootSMSCallbackStore.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSPrivilegedResult.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSResultCode.java"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$OUT:$ANDROID_JAR" -d "$OUT" \
  "$ROOT/test/android/os/Build.java" \
  "$ROOT/test/cloud-call/android/os/SystemClock.java" \
  "$ROOT/test/android/content/IntentFilter.java" \
  "$ROOT"/test/sms-confirmation/android/content/*.java \
  "$ROOT"/test/sms-confirmation/android/app/*.java \
  "$ROOT"/test/sms-confirmation/android/telephony/*.java \
  "$ROOT"/test/sms-confirmation/android/os/*.java \
  "$ROOT"/test/sms-confirmation/com/airsim/phonecontrol/*.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.PrivilegedSmsConfirmationTests
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.RootSMSCallbackProviderTests
