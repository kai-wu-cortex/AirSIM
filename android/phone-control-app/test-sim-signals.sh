#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-sim-signals.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
ANDROID_JAR="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platforms/android-35/android.jar"
JSON_JAR="$ROOT/build/dependencies/json-20240303.jar"
if [ ! -f "$JSON_JAR" ]; then
    mkdir -p "$(dirname "$JSON_JAR")"
    curl -fsSL https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$JSON_JAR"
fi
test "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" = 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
find "$ROOT/test/sim-signals" -name '*.java' > "$OUT/sources"
printf '%s\n' "$ROOT/src/com/airsim/phonecontrol/SimSlotJson.java" >> "$OUT/sources"
# javac argument files require quoting paths containing spaces.
sed 's/.*/"&"/' "$OUT/sources" > "$OUT/quoted"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$ANDROID_JAR:$JSON_JAR" -d "$OUT/classes" @"$OUT/quoted"
"$TASK_JAVA_HOME/bin/java" -cp "$OUT/classes:$JSON_JAR" com.airsim.phonecontrol.SimSignalTests
