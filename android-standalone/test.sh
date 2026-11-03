#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$ROOT/AndroidManifest.xml"

assert_contains() {
  if ! grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_not_contains() {
  if grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_contains "$ROOT/../android/phone-control-app/src/com/airsim/phonecontrol/StandaloneAgentGateway.java" \
  'case "/api/calls/dtmf" -> command("dtmf", localCallTarget("dtmf", input)' \
  'standalone DTMF must preserve the explicitly requested published call identity'

S="$ROOT/../android/phone-control-app/src/com/airsim/phonecontrol/StandaloneAgentService.java"
assert_contains "$S" 'registrationRecovery.takeResync(' \
  'registration sync must honour relay 401 recovery'
assert_contains "$S" 'registrationRecovery.onFailure(heartbeatError' \
  'heartbeat 401 must request re-registration'
assert_contains "$S" 'registrationRecovery.onFailure(error, android.os.SystemClock.elapsedRealtime());' \
  'agent cycle 401 must request re-registration'
assert_contains "$S" 'registrationRecovery.onFailure(error, now);' \
  'command-channel 401 (HTTP poll or WebSocket handshake) must request re-registration'
assert_contains "$S" 'registrationRecovery.onAuthenticated()' \
  'successful heartbeat must reset recovery backoff'
assert_contains "$S" '"simulate-unauthorized"' \
  'dumpsys hook for live verification is missing'
assert_contains "$S" 'callEventRetry.shouldDrop(encoded, error, android.os.SystemClock.elapsedRealtime())' \
  'a call event the Relay keeps refusing must leave the queue'
assert_contains "$S" 'StandaloneCloudMediaManager.get(this).abandonCallEvent(encoded);' \
  'a dropped "ended" must still close its cloud call'
assert_contains "$S" '" " + CloudCallRetryPolicy.describe(error)' \
  'call event retries must log the Relay status'
assert_contains "$S" 'BridgeLog.error("standalone_call_event_drop_failed", abandonError);' \
  'a failure while closing a dropped call must not escape to the event worker thread'
assert_contains "$S" 'smsUploader.flush(' \
  'cloud SMS must go through the uploader so one message cannot block the queue'
assert_contains "$S" 'id -> relay.postJSON(registration, "/v1/events/sms", events.get(id), 12_000,' \
  'cloud SMS must be posted by the uploader'"'"'s sender'
assert_not_contains "$S" 'relay.postJSON(registration, "/v1/events/sms", event, 12_000)' \
  'the old in-loop SMS post (first failure blocks the queue) must be gone'
assert_contains "$S" 'smsStore.markCloudSent(id)' 'delivered SMS must leave the queue'
assert_contains "$S" 'smsStore.markCloudRejected(id)' 'rejected SMS must not be labelled delivered'
assert_contains "$S" 'worker.execute(this::smsLoop)' 'SMS must not block heartbeat or HTTP polling'
assert_contains "$S" 'smsTransport, snapshot.epoch()' 'SMS HTTP must be cancellable'
assert_contains "$S" 'android.os.SystemClock::elapsedRealtime' 'SMS cooldown must sample after failure'
assert_contains "$S" 'registrationRecovery.onFailure(smsError, android.os.SystemClock.elapsedRealtime());' \
  'an SMS upload 401 must still request re-registration'
assert_contains "$S" 'CloudSMSUploader.uploadTimestamp(source.optString("timestamp", ""), System.currentTimeMillis())' \
  'a carrier time in the future must be clamped before upload, or the Relay answers 400'
assert_contains "$S" '"standalone_sms_upload_retry verdict="' \
  'SMS retry logs must tell an unreachable Relay from a refusing one'
M="$ROOT/../android/phone-control-app/src/com/airsim/phonecontrol/StandaloneCloudMediaManager.java"
assert_contains "$M" 'mediaRetry.outcome(error, CallRepository.state(descriptor.androidID),' \
  'a media session must ask the retry policy about every failed connect'
assert_contains "$M" 'if (outcome != CloudCallRetryPolicy.MediaOutcome.RECONNECT)' \
  'a media session must stop once the Relay no longer has its call'
assert_contains "$M" 'outcome == CloudCallRetryPolicy.MediaOutcome.STOP_AND_RELEASE && active == this' \
  'a live Telecom call keeps its slot after media give-up, so its retried ring cannot push the iPhone again'
assert_contains "$M" '"standalone_cloud_call_closed_unconfirmed call_uuid="' \
  'closing a call whose "ended" was dropped must log which cloud call it was'
assert_contains "$M" '"standalone_cloud_media_abandoned call_uuid="' \
  'abandoning a media session must log which cloud call it was'
assert_contains "$M" 'void abandonCallEvent(String encoded)' \
  'media manager must close a call whose "ended" was dropped'
assert_contains "$M" 'active != null && CloudCallTarget.owns(active.descriptor.androidID, androidID)' \
  'a dropped "ended" may only close the cloud call of the same Android call'
assert_contains "$M" 'if (descriptor != null && !CloudCallTarget.owns(descriptor.androidID, androidID))' \
  'only the cloud call'"'"'s own Telecom events may drive it (call waiting, late events of an earlier call)'
assert_contains "$M" 'try { event = new JSONObject(encoded); } catch (Exception ignored) { return; }' \
  'an unparsable dropped event must not escape the event worker'

assert_contains "$MANIFEST" 'package="com.airsim.phonecontrol.standalone"' \
  'standalone package id is missing'
assert_contains "$MANIFEST" 'android:versionCode="126"' \
  'standalone version code does not match the current candidate build'
assert_contains "$MANIFEST" 'android:versionName="0.9.8.21"' \
  'standalone version name does not match the current Android candidate'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.STANDALONE_AGENT' \
  'standalone runtime flag is missing'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.StandaloneAgentService' \
  'embedded Agent foreground service is missing'
assert_contains "$MANIFEST" 'android.permission.RECEIVE_SMS' \
  'standalone cannot receive carrier SMS'
assert_contains "$MANIFEST" 'android.permission.READ_SMS' \
  'standalone cannot use the optional inbox fallback'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.IncomingSMSReceiver' \
  'standalone carrier SMS receiver is missing'
assert_not_contains "$MANIFEST" 'com.android.virtualization.terminal' \
  'standalone APK must not query or depend on Linux Terminal'
assert_not_contains "$MANIFEST" 'AgentWatchdogService' \
  'standalone APK must not declare the AVF watchdog'

"$ROOT/../android/phone-control-app/test.sh"
"$ROOT/../android/phone-audio-bridge/build.sh"

"$ROOT/build.sh" >/dev/null
sh "$ROOT/../android/phone-control-app/test-cloud-call.sh"
sh "$ROOT/../android/phone-control-app/test-gateway-lifecycle.sh"
sh "$ROOT/../android/phone-control-app/test-owned-dial.sh"
sh "$ROOT/../android/phone-control-app/test-pure-local-integration.sh"
APK="$ROOT/build/android/AirSIM-Android-Standalone-debug.apk"
APKANALYZER=${APKANALYZER:-$(command -v apkanalyzer || true)}
if [ -z "$APKANALYZER" ]; then
  echo "FAIL: apkanalyzer is required to verify the built role manifest" >&2
  exit 1
fi
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home} \
  "$APKANALYZER" manifest print "$APK" | python3 "$ROOT/test/verify_dialer_manifest.py"
echo "Standalone Bridge tests passed"
