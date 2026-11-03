#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node "$ROOT/test/check-egress-startup.cjs"
OUT="$ROOT/build/pure-local-tests"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
CRYPTO=$(sh "$ROOT/crypto-dependency.sh")
JSON_JAR="$ROOT/build/dependencies/json-20240303.jar"
if [ ! -f "$JSON_JAR" ]; then
  mkdir -p "$ROOT/build/dependencies"
  curl -fsSL https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$JSON_JAR"
fi
test "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" = 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
mkdir -p "$OUT"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$CRYPTO:$JSON_JAR" -d "$OUT" \
  "$ROOT/src/com/airsim/phonecontrol/StandaloneRelayClient.java" \
  "$ROOT/src/com/airsim/phonecontrol/RelayHTTPException.java" \
  "$ROOT/src/com/airsim/phonecontrol/RelayCommandRetryState.java" \
  "$ROOT/src/com/airsim/phonecontrol/WebSocketPeerClose.java" \
  "$ROOT/test/com/airsim/phonecontrol/StandaloneRelayEgressTests.java" \
  "$ROOT/src/com/airsim/phonecontrol/PureLocalModePolicy.java" \
  "$ROOT/src/com/airsim/phonecontrol/PureLocalModeProof.java" \
  "$ROOT/src/com/airsim/phonecontrol/PureLocalModeWire.java" \
  "$ROOT/test/com/airsim/phonecontrol/PureLocalModeWireTests.java" \
  "$ROOT/src/com/airsim/phonecontrol/RelayEgressGate.java" \
  "$ROOT/src/com/airsim/phonecontrol/RelayEventQueue.java" \
  "$ROOT/test/com/airsim/phonecontrol/RelayEventQueueTests.java" \
  "$ROOT/src/com/airsim/phonecontrol/PureLocalModeStore.java" \
  "$ROOT/src/com/airsim/phonecontrol/PureLocalModeCoordinator.java" \
  "$ROOT/test/com/airsim/phonecontrol/PureLocalModeCoordinatorTests.java" \
  "$ROOT/test/com/airsim/phonecontrol/PureLocalModeStoreTests.java" \
  "$ROOT/test/com/airsim/phonecontrol/RelayEgressGateTests.java" \
  "$ROOT/test/com/airsim/phonecontrol/PureLocalModePolicyTests.java"
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO" com.airsim.phonecontrol.PureLocalModePolicyTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO" com.airsim.phonecontrol.RelayEgressGateTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO" com.airsim.phonecontrol.RelayEventQueueTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO" com.airsim.phonecontrol.PureLocalModeStoreTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO" com.airsim.phonecontrol.PureLocalModeCoordinatorTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO:$JSON_JAR" com.airsim.phonecontrol.StandaloneRelayEgressTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$OUT:$CRYPTO:$JSON_JAR" com.airsim.phonecontrol.PureLocalModeWireTests
