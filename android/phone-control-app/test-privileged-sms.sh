#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test/privileged-sms"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
mkdir -p "$OUT"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$ANDROID_JAR" \
  -sourcepath "$ROOT/src" -d "$OUT" \
  "$ROOT/src/com/airsim/phonecontrol/ShizukuBridgeUserService.java" \
  "$ROOT/src/com/airsim/phonecontrol/ShellProviderQuery.java"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$OUT:$ANDROID_JAR" -d "$OUT" \
  "$ROOT"/test/android/os/Build.java "$ROOT"/test/android/util/Log.java \
  "$ROOT"/test/privileged-sms/android/os/*.java \
  "$ROOT"/test/privileged-sms/android/app/*.java \
  "$ROOT"/test/privileged-sms/android/content/*.java \
  "$ROOT"/test/privileged-sms/android/net/*.java \
  "$ROOT"/test/privileged-sms/android/provider/*.java \
  "$ROOT"/test/privileged-sms/android/telephony/*.java \
  "$ROOT"/test/privileged-sms/org/json/*.java \
  "$ROOT"/test/privileged-sms/com/airsim/phonecontrol/*.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.PrivilegedSMSTests
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.ShellProviderQueryTests
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.PrivilegedInboxTests
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" com.airsim.phonecontrol.PCMOwnershipTests

"$TASK_JAVA_HOME/bin/javac" --release 17 -d "$OUT" \
  "$ROOT/src/com/airsim/phonecontrol/SMSInboxCursor.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSInboxCatchUp.java" \
  "$ROOT/test/com/airsim/phonecontrol/SMSInboxCatchUpTests.java"
"$TASK_JAVA_HOME/bin/java" -cp "$OUT" com.airsim.phonecontrol.SMSInboxCatchUpTests
