#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-test"
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
CRYPTO_JAR=$(sh "$ROOT/crypto-dependency.sh")

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
assert_contains "$ROOT/AndroidManifest.xml" 'android.permission.RECEIVE_SMS' \
  'incoming SMS permission is missing'
assert_contains "$ROOT/AndroidManifest.xml" 'android.permission.READ_SMS' \
  'optional inbox fallback permission is missing'
assert_contains "$ROOT/AndroidManifest.xml" 'android:name=".IncomingSMSReceiver"' \
  'carrier SMS receiver is missing'
assert_contains "$ROOT/src/com/airsim/phonecontrol/StandaloneAgentGateway.java" \
  'smsStore.localMessages().toString()' 'standalone SMS inbox is not exposed to iPhone'
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
"$JAVAC" --release 17 -cp "$CRYPTO_JAR" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/RelayHTTPException.java \
  "$ROOT"/src/com/airsim/phonecontrol/CloudCallTarget.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayCommandRetryState.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayCommandConfiguration.java \
  "$ROOT"/src/com/airsim/phonecontrol/StandaloneWebSocket.java \
  "$ROOT"/test/android/util/Base64.java \
  "$ROOT"/test/com/airsim/phonecontrol/StandaloneCommandLifecycleTests.java \
  "$ROOT"/src/com/airsim/phonecontrol/WebSocketPeerClose.java \
  "$ROOT"/src/com/airsim/phonecontrol/CommandPollingPolicy.java \
  "$ROOT"/test/com/airsim/phonecontrol/RelayCommandRetryTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/WebSocketPeerCloseTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.RelayCommandRetryTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.WebSocketPeerCloseTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.StandaloneCommandLifecycleTests
"$JAVAC" --release 17 -cp "$CRYPTO_JAR" -d "$OUT" \
  "$ROOT"/test/android/Manifest.java \
  "$ROOT"/test/android/provider/Settings.java \
  "$ROOT"/test/android/content/SharedPreferences.java \
  "$ROOT"/test/android/content/ComponentName.java \
  "$ROOT"/test/android/content/Intent.java \
  "$ROOT"/test/android/content/pm/PackageManager.java \
  "$ROOT"/test/android/content/pm/PackageInfo.java \
  "$ROOT"/test/android/os/Bundle.java \
  "$ROOT"/test/android/os/Build.java \
  "$ROOT"/test/android/telecom/PhoneAccount.java \
  "$ROOT"/test/android/telecom/PhoneAccountHandle.java \
  "$ROOT"/test/android/telephony/TelephonyManager.java \
  "$ROOT"/test/android/telephony/PhoneNumberUtils.java \
  "$ROOT"/test/android/telephony/SubscriptionManager.java \
  "$ROOT"/test/android/telephony/SubscriptionInfo.java \
  "$ROOT"/test/android/telephony/SmsManager.java \
  "$ROOT"/test/org/json/JSONException.java \
  "$ROOT"/test/org/json/JSONObject.java \
  "$ROOT"/test/org/json/JSONArray.java \
  "$ROOT"/test/android/content/Context.java \
  "$ROOT"/test/android/net/Uri.java \
  "$ROOT"/test/android/os/Looper.java \
  "$ROOT"/test/android/os/Handler.java \
  "$ROOT"/test/android/telecom/Call.java \
  "$ROOT"/test/android/telecom/TelecomManager.java \
  "$ROOT"/test/android/telecom/VideoProfile.java \
  "$ROOT"/test/com/airsim/phonecontrol/AppConfig.java \
  "$ROOT"/test/com/airsim/phonecontrol/BridgeLog.java \
	"$ROOT"/test/com/airsim/phonecontrol/RuntimeMode.java \
	"$ROOT"/test/com/airsim/phonecontrol/StandaloneAgentGateway.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentClient.java \
  "$ROOT"/src/com/airsim/phonecontrol/InstallerClient.java \
  "$ROOT"/src/com/airsim/phonecontrol/ReleaseAssetSelector.java \
  "$ROOT"/src/com/airsim/phonecontrol/AVFStartupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/RuntimePermissionPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSDeliveryIdentity.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSRecentDeliveryIDs.java \
	"$ROOT"/src/com/airsim/phonecontrol/SMSInboxCursor.java \
  "$ROOT"/src/com/airsim/phonecontrol/TelecomStateMapper.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomRolePolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/DialerRoleSetupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/ShizukuStartupPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/TelecomInvocation.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeProtocol.java \
	"$ROOT"/src/com/airsim/phonecontrol/PrivilegedBridgeCoordinator.java \
  "$ROOT"/src/com/airsim/phonecontrol/AudioWatchdogSnapshot.java \
  "$ROOT"/src/com/airsim/phonecontrol/PCMHealthEvidence.java \
  "$ROOT"/test/com/airsim/phonecontrol/PCMHealthEvidenceTests.java \
	"$ROOT"/src/com/airsim/phonecontrol/PhoneAudioBridgeProcessPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/WireJson.java \
  "$ROOT"/src/com/airsim/phonecontrol/DebugRedactor.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportFormatter.java \
  "$ROOT"/src/com/airsim/phonecontrol/AppInformation.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportStore.java \
  "$ROOT"/src/com/airsim/phonecontrol/CrashReportSharePayload.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentCommand.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallRepository.java \
  "$ROOT"/src/com/airsim/phonecontrol/DefaultCallAccount.java \
  "$ROOT"/src/com/airsim/phonecontrol/SIMSlotInfo.java \
  "$ROOT"/src/com/airsim/phonecontrol/SIMSlotManager.java \
  "$ROOT"/src/com/airsim/phonecontrol/CloudCallTarget.java \
  "$ROOT"/src/com/airsim/phonecontrol/AgentCommandDispatcher.java \
  "$ROOT"/src/com/airsim/phonecontrol/SMSPayloadPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/SMSConfirmation.java \
  "$ROOT"/src/com/airsim/phonecontrol/RetryPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayHTTPException.java \
  "$ROOT"/src/com/airsim/phonecontrol/RelayRetryPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CommandPollingPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/RecoveryPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/RecoveryLaunchPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallEventDeduplicator.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingCrypto.java \
  "$ROOT"/src/com/airsim/phonecontrol/PairingSession.java \
	"$ROOT"/src/com/airsim/phonecontrol/AVFNetworkPolicy.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANAuth.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANControlPolicy.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANAcceptLoop.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANPeerLifecycle.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANReplayCache.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPCMProtocol.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPortBinder.java \
	"$ROOT"/src/com/airsim/phonecontrol/VoWLANNetworkPolicy.java \
    "$ROOT"/src/com/airsim/phonecontrol/DirectGatewayRoutes.java \
    "$ROOT"/src/com/airsim/phonecontrol/DirectCallOwnership.java \
    "$ROOT"/src/com/airsim/phonecontrol/RemoteCallAudioScope.java \
	"$ROOT"/src/com/airsim/phonecontrol/StandaloneLongPoll.java \
	"$ROOT"/src/com/airsim/phonecontrol/MainScreenPresentation.java \
	"$ROOT"/src/com/airsim/phonecontrol/LiveStatusPoller.java \
	"$ROOT"/src/com/airsim/phonecontrol/PCMBridgeStatus.java \
	"$ROOT"/src/com/airsim/phonecontrol/MuteRequestRetrier.java \
	"$ROOT"/src/com/airsim/phonecontrol/NotificationUpdateGate.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEProtocol.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEAudioQueue.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEPairingManager.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLECredentialStore.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEReplayWindow.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEControlChannel.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLECallController.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEPCMBackendResolver.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEDiagnostics.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEPCMBridgeSession.java \
	"$ROOT"/src/com/airsim/phonecontrol/voble/VoBLEMediaSession.java \
	"$ROOT"/test/com/airsim/phonecontrol/CoreTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/PairingCryptoCompatibilityTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/NotificationUpdateGateTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/CallRepositoryTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/DefaultCallAccountTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/SIMSlotManagerTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/ShizukuStartupPolicyTests.java
"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/AndroidAgentIdentity.java \
  "$ROOT"/test/com/airsim/phonecontrol/AndroidAgentIdentityTests.java
sh "$ROOT/verify-io-api.sh" "$OUT"
"$JAVA" -cp "$OUT:$CRYPTO_JAR" com.airsim.phonecontrol.CoreTests
"$JAVA" -cp "$OUT:$CRYPTO_JAR" com.airsim.phonecontrol.PairingCryptoCompatibilityTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.PCMHealthEvidenceTests
sh "$ROOT/test-voble-gatt.sh"
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.NotificationUpdateGateTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CallRepositoryTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.DefaultCallAccountTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.SIMSlotManagerTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.AndroidAgentIdentityTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.ShizukuStartupPolicyTests

# Keep the real diagnostics class ahead of the unrelated suite's BridgeLog test double.
DIAGNOSTICS_OUT="$OUT/diagnostics"
mkdir -p "$DIAGNOSTICS_OUT"
"$JAVAC" --release 17 -cp "$OUT" -d "$DIAGNOSTICS_OUT" \
  "$ROOT"/test/android/util/Log.java \
  "$ROOT"/src/com/airsim/phonecontrol/BridgeLog.java \
  "$ROOT"/test/com/airsim/phonecontrol/DiagnosticFileTests.java
sh "$ROOT/verify-io-api.sh" "$DIAGNOSTICS_OUT"
"$JAVA" -cp "$DIAGNOSTICS_OUT:$OUT" com.airsim.phonecontrol.DiagnosticFileTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/LocalOutputMuteController.java \
  "$ROOT"/src/com/airsim/phonecontrol/CallOutputPolicyMute.java \
  "$ROOT"/src/com/airsim/phonecontrol/BoundedAudioOperation.java \
  "$ROOT"/src/com/airsim/phonecontrol/SystemCallOutputPolicy.java \
  "$ROOT"/test/com/airsim/phonecontrol/CallOutputPolicyMuteTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/LocalOutputMuteControllerTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.LocalOutputMuteControllerTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CallOutputPolicyMuteTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/AudioWatchdogSnapshot.java \
  "$ROOT"/src/com/airsim/phonecontrol/RemoteAudioWatchdog.java \
  "$ROOT"/src/com/airsim/phonecontrol/RemoteCallAudioScope.java \
  "$ROOT"/src/com/airsim/phonecontrol/AudioWatchdogReport.java \
  "$ROOT"/src/com/airsim/phonecontrol/BoundedAudioOperation.java \
  "$ROOT"/test/com/airsim/phonecontrol/BoundedAudioOperationTests.java \
  "$ROOT"/test/com/airsim/phonecontrol/RemoteAudioWatchdogTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.RemoteAudioWatchdogTests
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.BoundedAudioOperationTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANNetworkRecoveryGate.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANAdvertisementEpoch.java \
  "$ROOT"/test/com/airsim/phonecontrol/VoWLANNetworkRecoveryTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.VoWLANNetworkRecoveryTests

# Compile the actual executor against Android; replace only the telephony boundary at runtime.
ANDROID_JAR="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platforms/android-35/android.jar"
SMS_OUT="$OUT/sms-compat"
mkdir -p "$SMS_OUT"
"$JAVAC" --release 17 -cp "$ANDROID_JAR:$DIAGNOSTICS_OUT:$OUT" -d "$SMS_OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/SMSCommandExecutor.java
"$JAVAC" --release 17 -cp "$SMS_OUT:$OUT:$ANDROID_JAR" -d "$SMS_OUT" \
  "$ROOT"/test/compat/android/telephony/SmsManager.java \
  "$ROOT"/test/com/airsim/phonecontrol/SMSCompatibilityTests.java
"$JAVA" -cp "$SMS_OUT:$OUT:$ANDROID_JAR" com.airsim.phonecontrol.SMSCompatibilityTests

"$JAVAC" --release 17 -cp "$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/CloudPCMAudioQueue.java \
  "$ROOT"/test/com/airsim/phonecontrol/CloudPCMAudioQueueTests.java
"$JAVA" -cp "$OUT" com.airsim.phonecontrol.CloudPCMAudioQueueTests

"$JAVAC" --release 17 -cp "$DIAGNOSTICS_OUT:$OUT" -d "$OUT" \
  "$ROOT"/src/com/airsim/phonecontrol/CloudPCMMediaPump.java \
  "$ROOT"/test/com/airsim/phonecontrol/CloudPCMMediaPumpTests.java
"$JAVA" -cp "$DIAGNOSTICS_OUT:$OUT" com.airsim.phonecontrol.CloudPCMMediaPumpTests

PCM_OUT="$OUT/direct-pcm"
mkdir -p "$PCM_OUT"
"$JAVAC" --release 17 -cp "$OUT:$ANDROID_JAR" -d "$PCM_OUT" \
  "$ROOT"/test/pcm/com/airsim/phonecontrol/VoWLANPairingStore.java \
  "$ROOT"/test/pcm/com/airsim/phonecontrol/RemoteAudioSessionRegistry.java \
  "$ROOT"/src/com/airsim/phonecontrol/VoWLANPCMRelay.java \
  "$ROOT"/test/com/airsim/phonecontrol/DirectPCMIntegrationTests.java
"$JAVA" -cp "$PCM_OUT:$OUT:$ANDROID_JAR" com.airsim.phonecontrol.DirectPCMIntegrationTests

sh "$ROOT/test-audio-policy.sh"
