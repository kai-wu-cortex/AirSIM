#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test"
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"

assert_contains() {
  file=$1
  expected=$2
  message=$3
  if ! grep -Fq "$expected" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_not_contains() {
  file=$1
  unexpected=$2
  message=$3
  if grep -Fq "$unexpected" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

assert_contains "$ROOT/AndroidManifest.xml" \
  'android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING' \
  'boot-safe watchdog permission is missing'
assert_contains "$ROOT/AndroidManifest.xml" \
  'android:foregroundServiceType="remoteMessaging"' \
  'boot-safe foreground service type is missing'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING' \
  'watchdog still requests a boot-blocked foreground service type'
assert_contains "$ROOT/src/com/airsim/phonecontrol/VoWLANGatewayService.java" \
  'ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING' \
  'VoWLAN gateway still requests a boot-blocked foreground service type'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'setPendingIntentCreatorBackgroundActivityStartMode' \
  'Terminal recovery does not grant creator-side background launch privileges'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'setPendingIntentBackgroundActivityStartMode' \
  'Terminal recovery does not grant sender-side background launch privileges'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'PendingIntent.getActivity' \
  'Terminal recovery still bypasses the supported PendingIntent launch path'
assert_not_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'startActivity(terminal)' \
  'Terminal recovery still uses a background activity start that Android blocks'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'String payload = new AgentClient(this).nextCommand();' \
  'watchdog does not refresh the AVF Agent endpoint for each reconnect'
assert_not_contains "$ROOT/src/com/airsim/phonecontrol/AgentWatchdogService.java" \
  'AgentClient client = new AgentClient(this);' \
  'watchdog still caches a pre-boot AVF endpoint for its entire lifetime'
assert_contains "$ROOT/AndroidManifest.xml" \
  'android:name=".BridgeApplication"' \
  'persistent diagnostics are not initialized at process start'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentClient.java" \
  'http_request_started' \
  'Agent HTTP connection attempts are missing from debug diagnostics'
assert_contains "$ROOT/src/com/airsim/phonecontrol/AgentClient.java" \
  'http_request_finished' \
  'Agent HTTP response status and timing are missing from debug diagnostics'
assert_contains "$ROOT/src/com/airsim/phonecontrol/MainActivity.java" \
  'Debug 日志' \
  'the Android app has no user-visible debug log controls'
assert_contains "$ROOT/src/com/airsim/phonecontrol/MainActivity.java" \
  'BridgeLog.clear()' \
  'the Android app cannot clear captured diagnostics'

rm -rf "$OUT"
mkdir -p "$OUT"
"$JAVAC" --release 17 -d "$OUT" \
  "$ROOT"/test/android/content/Context.java \
  "$ROOT"/test/com/airsim/phonecontrol/AppConfig.java \
  "$ROOT"/test/com/airsim/phonecontrol/BridgeLog.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentClient.java \
  "$ROOT"/src/com/airsim/phonecontrol/InstallerClient.java \
  "$ROOT"/src/com/airsim/phonecontrol/ReleaseAssetSelector.java \
  "$ROOT"/src/com/airsim/phonecontrol/AVFStartupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/RuntimePermissionPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/TelecomStateMapper.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomRolePolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomInvocation.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeProtocol.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeCoordinator.java \
  "$ROOT"/src/com/airsim/phonecontrol/WireJson.java \
  "$ROOT"/src/com/airsim/phonecontrol/DebugRedactor.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentCommand.java \
  "$ROOT"/src/com/airsim/phonecontrol/SMSPayloadPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/RetryPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/RecoveryPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/RecoveryLaunchPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallEventDeduplicator.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingCrypto.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingSession.java \
	"$ROOT"/src/com/airsim/phonecontrol/AVFNetworkPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANAuth.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANControlPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANPeerLifecycle.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANReplayCache.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPCMProtocol.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANNetworkPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/MainScreenPresentation.java \
  "$ROOT"/test/com/airsim/phonecontrol/CoreTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CoreTests
