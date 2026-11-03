#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE="$ROOT/build/jvm-test"
OUT="$BASE/owned-dial"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
BUILT="$ROOT/../../android-standalone/build/android/classes"
JSON_JAR="$ROOT/build/dependencies/json-20240303.jar"
mkdir -p "$OUT" "$ROOT/build/dependencies"
if [ ! -f "$JSON_JAR" ]; then
  curl -fsSL https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$JSON_JAR"
fi
test "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" = 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$JSON_JAR:$BUILT:$BASE:$ANDROID_JAR" -d "$OUT" \
  "$ROOT"/test/owned-dial/com/airsim/phonecontrol/*.java \
  "$ROOT"/test/pcm/com/airsim/phonecontrol/VoWLANPairingStore.java \
  "$ROOT"/test/gateway-lifecycle/com/airsim/phonecontrol/RuntimeMode.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANControlGateway.java \
  "$ROOT"/test/com/airsim/phonecontrol/OwnedDialGatewayTests.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$JSON_JAR:$BASE:$BUILT:$ANDROID_JAR" com.airsim.phonecontrol.OwnedDialGatewayTests
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$JSON_JAR:$BASE:$ANDROID_JAR" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/AppReleaseClient.java \
  "$ROOT"/test/com/airsim/phonecontrol/AppReleaseClientTests.java
"$TASK_JAVA_HOME/bin/java" -cp "$OUT:$JSON_JAR:$BASE:$ANDROID_JAR" com.airsim.phonecontrol.AppReleaseClientTests
