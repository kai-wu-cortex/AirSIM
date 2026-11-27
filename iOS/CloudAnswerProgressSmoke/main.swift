import Foundation

var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { fatalError(message) }
}
let start = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
func begun() -> CloudAnswerProgress {
    var value = CloudAnswerProgress(startedAt: start)
    value.apply(.cloudAnswerStarted, at: start)
    return value
}
// A route still being resolved never owns a cloud deadline.
var pendingLocal = CloudAnswerProgress(startedAt: start)
pendingLocal.tick(at: at(120))
check(pendingLocal.failure == nil, "Local discovery cannot time out a cloud attempt that never started")
pendingLocal.apply(.cloudAnswerStarted, at: at(120))
pendingLocal.tick(at: at(129))
check(pendingLocal.failure == nil, "Cloud receives its own budget")
pendingLocal.apply(.cloudAnswerStarted, at: at(129))
pendingLocal.tick(at: at(130))
check(pendingLocal.failure == .cloudUnreachable, "Duplicate answer cannot extend the deadline")

// Parallel HTTP/WS: failure or success may arrive in either order.
for httpFirst in [true, false] {
    var value = begun()
    if httpFirst { value.apply(.relayUnavailable, at: at(0.1)) }
    value.apply(.control(status: "answer_ok", role: nil), at: at(0.2))
    if !httpFirst { value.apply(.relayUnavailable, at: at(0.3)) }
    check(value.failure == nil, "An HTTP failure does not end a viable WebSocket answer")
    value.apply(.control(status: "active", role: nil), at: at(1))
    value.apply(.control(status: "pcm_first_frame", role: nil), at: at(2))
    check(value.connectedAt == nil, "Agent status does not prove local playback")
    value.apply(.downlinkAudio, at: at(3))
    check(value.connectedAt == at(3), "Only actual local playback finishes progress")
    value.tick(at: at(40))
    check(value.failure == nil, "Completed progress cannot later time out")
}
var unavailable = begun()
unavailable.apply(.relayUnavailable, at: at(1))
unavailable.tick(at: at(9))
check(unavailable.failure == nil, "Best-effort HTTP failure keeps the remaining budget")
unavailable.tick(at: at(10))
check(unavailable.failure == .cloudUnavailable, "Failure reason is retained when all progress stalls")

// ACTIVE with no actual PCM still gets the bounded voice timeout.
for status in ["answer_ok", "active", "pcm_first_frame"] {
    var value = begun()
    value.apply(.control(status: status, role: nil), at: at(1))
    value.tick(at: at(15.9))
    check(value.failure == nil && value.connectedAt == nil, "Voice is not yet known ready")
    value.apply(.control(status: status, role: nil), at: at(15.9))
    value.tick(at: at(16))
    check(value.failure == .androidNoAudio(callAnswered: true), "Repeated status must not renew the voice deadline")
}
var offline = begun()
offline.apply(.earlyReceipt(agentConnected: false), at: at(2))
offline.apply(.control(status: "peer_connected", role: "iphone"), at: at(3))
check(offline.stage == .waitingForAndroid, "Another iPhone is not the agent")
offline.tick(at: at(12))
check(offline.failure == .androidOffline, "Queued but no agent is diagnosed")
var forwarded = begun()
forwarded.apply(.earlyReceipt(agentConnected: true), at: at(2))
forwarded.tick(at: at(12))
check(forwarded.failure == .androidUnresponsive, "Forwarded without response is diagnosed")

// Delayed errors from unrelated actions / AVF must not fail this answer.
var unidentified = begun()
for status in ["action_error", "answer_unavailable"] {
    unidentified.apply(.control(status: status, role: nil, identified: false), at: at(1))
    check(unidentified.failure == nil, "Failure requires complete call identity")
}
var refused = begun()
refused.apply(.control(status: "answer_unavailable", role: nil), at: at(1))
check(refused.failure == .androidNoAudio(callAnswered: false), "Explicit refusal never picks up the carrier call")
check(refused.failure?.endsAndroidCall == false, "Refusal keeps carrier ringing")
var retry = begun()
retry.apply(.control(status: "action_error", role: nil), at: at(1))
retry.tick(at: at(5))
check(retry.failure == nil, "Transient action error gets a bounded retry opportunity")
retry.apply(.control(status: "answer_ok", role: nil), at: at(5))
retry.apply(.control(status: "answer_unavailable", role: nil), at: at(6))
retry.apply(.control(status: "action_error", role: nil), at: at(7))
retry.tick(at: at(8))
check(retry.failure == nil, "Stale refusal/error must not undo a confirmed answer")
retry.apply(.downlinkAudio, at: at(9))
check(retry.connectedAt == at(9), "Recovered answer reaches playback")
var failed = begun()
failed.apply(.control(status: "action_error", role: nil), at: at(1))
failed.tick(at: at(6))
check(failed.failure == .androidAnswerFailed, "Persistent failure is bounded")

let uuid = UUID(), other = UUID()
check(CloudAnswerProgressPolicy.mayEnd(failed: uuid, systemCall: uuid, sessionCall: uuid), "Own session cleanup")
check(!CloudAnswerProgressPolicy.mayEnd(failed: uuid, systemCall: uuid, sessionCall: nil), "No cloud session means no cleanup authority")
check(!CloudAnswerProgressPolicy.mayEnd(failed: uuid, systemCall: other, sessionCall: uuid), "Never end replacement CallKit")
check(!CloudAnswerProgressPolicy.mayEnd(failed: uuid, systemCall: uuid, sessionCall: other), "Never stop replacement media")
check(CloudAnswerProgressPolicy.mayEnd(failed: uuid, systemCall: nil, sessionCall: uuid), "App-only cloud session can clean itself up")
check(!CloudAnswerFailure.answeredElsewhere.endsAndroidCall, "Never hang up another owner")
check(!CloudAnswerFailure.answeredElsewhere.notifies, "Ownership change is not an error notification")
check(CloudAnswerFailure.androidNoAudio(callAnswered: true).advice?.contains("Shizuku") == false, "Advice applies to modules and Root too")

let suite = "cloud-answer-progress-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
CloudAnswerDurationHistory.record(1, defaults: defaults)
CloudAnswerDurationHistory.record(2, defaults: defaults)
check(CloudAnswerDurationHistory.average(defaults: defaults) == nil, "Need three real playback samples")
CloudAnswerDurationHistory.record(3, defaults: defaults)
check(CloudAnswerDurationHistory.average(defaults: defaults) == 2, "Average local playback wait")
for seconds in 1...12 { CloudAnswerDurationHistory.record(Double(seconds), defaults: defaults) }
check((defaults.array(forKey: CloudAnswerDurationHistory.key) ?? []).count == 10, "Bounded history")
check(CloudAnswerDurationHistory.average(defaults: defaults) == 8, "Average latest ten only")
print("cloud answer progress checks passed: \(assertions) assertions")
