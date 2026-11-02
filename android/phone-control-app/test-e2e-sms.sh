#!/bin/sh
# JVM tests for end-to-end encrypted cloud SMS (issue #24): real javax.crypto and org.json.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test/e2e-sms"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
JSON_JAR="$ROOT/build/dependencies/json-20240303.jar"
mkdir -p "$OUT" "$ROOT/build/dependencies"
if [ ! -f "$JSON_JAR" ]; then
  curl -fsSL https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$JSON_JAR"
fi
test "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" = 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
# Production classes come in through -sourcepath as the tests reference them.
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$JSON_JAR:$ANDROID_JAR" -sourcepath "$ROOT/src" -d "$OUT" \
  "$ROOT"/test/e2e-sms/com/airsim/phonecontrol/*.java
for test in "$ROOT"/test/e2e-sms/com/airsim/phonecontrol/*Tests.java; do
  "$TASK_JAVA_HOME/bin/java" -cp "$OUT:$JSON_JAR:$ANDROID_JAR" "com.airsim.phonecontrol.$(basename "$test" .java)"
done
