import Foundation
import CryptoKit

private actor DialProbe: OutgoingCallServicing {
    var attempts = 0
    func warmAudioHost() async throws {}
    func setAudioHostEnabled(_ enabled: Bool) async throws {}
    func dial(number: String) async throws { attempts += 1; throw URLError(.timedOut) }
}
private actor LegacyProbe: LegacyAgentPolling {
    let value: CallStatus
    var smsQueries = 0
    init(_ value: CallStatus) { self.value = value }
    func callStatus() async throws -> CallStatus { value }
    func smsStatus() async throws -> SMSStatus { smsQueries += 1; throw URLError(.timedOut) }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func event(_ id: String, _ uuid: UUID, _ state: CallLifecycleState, _ time: Double = 100) -> CallLifecycleEvent {
            .init(callID: id, callUUID: uuid, generation: 1, state: state, source: .agent,
                  timestamp: Date(timeIntervalSince1970: time), traceID: nil, failure: nil)
        }
        var lifecycle = CallLifecycleStore(); let first = UUID(), next = UUID()
        check(lifecycle.apply(event("A", first, .connecting)), "start")
        check(lifecycle.apply(event("A", first, .ended, 90)), "authoritative terminal despite clock skew")
        check(!lifecycle.snapshot.state.representsCall, "no running timer after terminal")
        check(!lifecycle.apply(event("A", first, .active, 101)), "late active cannot resurrect")
        check(lifecycle.apply(event("A", first, .ended, 102)), "duplicate terminal harmless")
        check(lifecycle.apply(event("B", next, .connecting, 103)), "new explicit call")
        check(!lifecycle.apply(event("A", first, .ended, 104)), "old terminal must not finish replacement")
        check(lifecycle.snapshot.callUUID == next && lifecycle.snapshot.state == .connecting, "replacement remains")
        check(lifecycle.apply(event("B", next, .active, 105)), "normal answer")
        check(lifecycle.apply(event("B", next, .ending, 106)), "normal local hangup")
        check(lifecycle.apply(event("B", next, .ended, 107)), "normal hangup ack")
        var gate = OutgoingDialIntentGate()
        check(gate.claim(first), "first intention admitted")
        check(!gate.claim(first) && !gate.claim(next), "no concurrent send")
        gate.finish(first)
        check(!gate.claim(first), "unknown response never re-executes same intent")
        check(gate.claim(next), "explicit next intent allowed client-side")
        gate.finish(first)
        check(gate.isInFlight, "old cleanup cannot release new attempt")
        gate.finish(next)
        var feedback = OutgoingEndFeedbackPolicy()
        check(feedback.consume(uuid: first, previousState: .connecting, outgoing: true, locallyEnded: false, authoritative: true), "neutral cue")
        check(!feedback.consume(uuid: first, previousState: .connecting, outgoing: true, locallyEnded: false, authoritative: true), "cue exactly once")
        for state in [CallLifecycleState.active, .ending, .ended, .ringing] {
            check(!feedback.consume(uuid: UUID(), previousState: state, outgoing: true, locallyEnded: false, authoritative: true), "no cue for answered/local/end/incoming")
        }
        check(!feedback.consume(uuid: next, previousState: .connecting, outgoing: true, locallyEnded: true, authoritative: true), "local cancellation silent")
        check(!feedback.consume(uuid: next, previousState: .connecting, outgoing: true, locallyEnded: false, authoritative: false), "no untrusted reason")
        let cancelled = DialProbe()
        do {
            try await OutgoingCallCoordinator.start(number: "fixture", service: cancelled, isCurrent: { false })
            preconditionFailure("Warmup cannot outlive dial intent")
        } catch { check(error is CancellationError, "warmup cancelled") }
        let cancelledAttempts = await cancelled.attempts
        check(cancelledAttempts == 0, "no carrier call after warmup cancellation")
        let probe = DialProbe(); var cloudSends = 0
        do {
            _ = try await OutgoingCallRouteCoordinator.start(number: "fixture", vowlanService: probe,
                cloudModeEnabled: true) { cloudSends += 1; return "cloud" }
            preconditionFailure("timeout must propagate")
        } catch {}
        let attempts = await probe.attempts
        check(attempts == 1 && cloudSends == 0, "no automatic second call after transport timeout")
        let cloud = try await OutgoingCallRouteCoordinator.start(number: "fixture", vowlanService: nil,
            cloudModeEnabled: true) { cloudSends += 1; return "cloud" }
        check(cloud == .cloud("cloud") && cloudSends == 1, "preselected cloud still works")
        let date = Date(timeIntervalSince1970: 100)
        let terminal = CallRecord(id: "A", index: 1, direction: "outgoing", state: "ended", number: nil,
            startedAt: date, updatedAt: date, endedAt: nil, missed: false)
        let legacy = LegacyProbe(.init(active: nil, history: [terminal], polling: true, eventDriven: false,
            pollIntervalSeconds: 1, lastPollError: "", revision: nil))
        let result = try await LegacyAgentPoller.next(legacy)
        let queries = await legacy.smsQueries
        check(result.call.history?.first?.isTerminal == true && queries == 0, "terminal not blocked on SMS I/O")
        let secret = try VoWLANCredential(secret: Data(repeating: 0x31, count: 32))
        func grant(agent: String = "A", call: String = "call", expiry: Int64 = 120,
                   version: Int = 1, direction: String = "recvonly", proof: String = "") -> EarlyMediaGrant {
            .init(version: version, agentID: agent, callID: call, sessionID: "session", expiresAt: expiry,
                state: "early_media", direction: direction, format: "s16le-8000-mono", proof: proof)
        }
        let bare = grant()
        check(bare.permits(agentID: "A", callID: "call", now: 100), "supported receive-only grant")
        for invalid in [grant(agent: "B"), grant(call: "old"), grant(expiry: 99), grant(expiry: 131),
                        grant(version: 2), grant(direction: "sendrecv")] {
            check(!invalid.permits(agentID: "A", callID: "call", now: 100), "invalid grant rejected")
        }
        let proof = Data(HMAC<SHA256>.authenticationCode(for: bare.proofMessage(nonce: "fresh"),
            using: SymmetricKey(data: secret.secret))).base64EncodedString()
        check(VoWLANHealthProof.verifyEarlyMedia(grant(proof: proof), nonce: "fresh", credential: secret), "authenticated grant")
        check(!VoWLANHealthProof.verifyEarlyMedia(grant(proof: proof), nonce: "replayed", credential: secret), "nonce replay rejected")
        check(!VoWLANHealthProof.verifyEarlyMedia(grant(call: "other", proof: proof), nonce: "fresh", credential: secret), "call binding")
        check(!VoWLANHealthProof.verifyEarlyMedia(grant(direction: "sendrecv", proof: proof), nonce: "fresh", credential: secret), "receive-only binding")
        check(!VoWLANHealthProof.verifyEarlyMedia(grant(), nonce: "fresh", credential: secret), "unsigned old peer denied")
        func operation(status: String = "confirmed", state: String = "ended", proof: String = "", dialProof: String? = nil) -> DialOperationStatus {
            .init(version: 1, agentID: "A", operationID: "intent", status: status,
                androidID: status == "confirmed" ? "android" : nil,
                backendID: status == "confirmed" ? "backend" : nil, callState: state,
                endedAt: state == "ended" ? "2026-11-03T00:00:00Z" : nil,
                operationProof: dialProof, statusProof: proof)
        }
        func mac(_ value: String) -> String {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8),
                using: SymmetricKey(data: secret.secret))).base64EncodedString()
        }
        let rawStatus = "AIRSIM-OPERATION1\nfresh\nA\nintent\nconfirmed\nandroid\nbackend\nended\n2026-11-03T00:00:00Z"
        let rawDial = "AIRSIM-DIAL1\nfresh\nintent\nandroid\nbackend"
        let receipt = operation(proof: mac(rawStatus), dialProof: mac(rawDial))
        check(receipt.proofMessage(nonce: "fresh") == Data(rawStatus.utf8), "gateway nine-field wire format")
        check(VoWLANHealthProof.verifyOperationStatus(receipt, nonce: "fresh", agentID: "A", operationID: "intent", credential: secret), "both recovery proofs")
        check(receipt.lifecycleState == .ended, "terminal recovery never becomes connecting")
        check(!VoWLANHealthProof.verifyOperationStatus(receipt, nonce: "stale", agentID: "A", operationID: "intent", credential: secret), "recovery nonce binding")
        check(!VoWLANHealthProof.verifyOperationStatus(receipt, nonce: "fresh", agentID: "B", operationID: "intent", credential: secret), "paired Agent binding")
        check(!VoWLANHealthProof.verifyOperationStatus(receipt, nonce: "fresh", agentID: "A", operationID: "other", credential: secret), "original operation binding")
        check(!VoWLANHealthProof.verifyOperationStatus(operation(dialProof: mac(rawDial)), nonce: "fresh", agentID: "A", operationID: "intent", credential: secret), "old dial proof alone insufficient")
        let unknown = operation(status: "unknown", state: "unknown", proof: mac("AIRSIM-OPERATION1\nfresh\nA\nintent\nunknown\n\n\nunknown\n"))
        check(VoWLANHealthProof.verifyOperationStatus(unknown, nonce: "fresh", agentID: "A", operationID: "intent", credential: secret), "unknown status with absent identity and trailing LF")
        check(unknown.lifecycleState == nil, "unknown never fabricates a call")
        print("PASS: \(checks) R18 client assertions (production policies; no device calls)")
    }
}
