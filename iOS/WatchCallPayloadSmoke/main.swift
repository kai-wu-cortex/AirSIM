import Foundation
import CryptoKit

var assertionCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !condition() { fatalError(message) }
}

do {
    let now = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!
    let call = try WatchVoIPCall(userInfo: [
        "event": "incoming_call",
        "call_id": "local-incoming-watch",
        "call_uuid": "D9B59660-05BB-4EA8-9AEB-4505B35C93F9",
        "number": "10086",
        "expires_at": "2026-09-27T10:00:45Z",
    ], now: now)
    check(call.callID == "local-incoming-watch", "Wrong local call ID")
    check(call.media == .pendingLocal, "Local incoming media must be obtained from iPhone")
    let secret = Data(repeating: 0x42, count: 32).base64EncodedString()
    let outgoing = try WatchVoIPCall(outgoingReply: [
        "call_id": "local-outgoing-watch", "call_uuid": UUID().uuidString,
        "number": "10086", "media_route": "vowlan", "pcm_host": "192.168.43.1",
        "pcm_port": 7591, "pcm_secret": secret,
    ])
    check(outgoing.isOutgoing, "Expected Watch outgoing call")
    check(outgoing.authenticatedMediaURL == nil, "Local media cannot use cloud URL")
    check(WatchLocalPCMEndpoint(dictionary: [
        "pcm_host": "8.8.8.8", "pcm_port": 7591, "pcm_secret": secret,
    ]) == nil, "Public PCM host must be rejected")
} catch {
    fatalError("Watch local incoming payload rejected: \(error)")
}

// Round 2: all declarations below are extracted from the actual Watch-only runtime.
for localOnly in [false, true] {
    for cached in [false, true] {
        check(WatchReliabilityPolicy.permitsCloud(vowlanOnly: localOnly, cachedPermission: cached) == (!localOnly && cached), "Cached policy override")
    }
}
for phase in [WatchCallPhase.idle, .incoming, .connecting, .active, .ended] {
    check(WatchReliabilityPolicy.phaseAfterMediaReady(phase) == phase, "Transport cannot change Android call phase")
}
for state in ["active", "held"] {
    check(WatchReliabilityPolicy.ringingResolution(state) == .answeredElsewhere, "An already connected call dismisses Watch ringing as answered elsewhere")
}
for state in ["ended", "failed", "disconnected"] {
    check(WatchReliabilityPolicy.ringingResolution(state) == .ended, "A confirmed terminal call dismisses Watch ringing")
}
for state in [nil, "", "incoming", "waiting", "connecting"] {
    check(WatchReliabilityPolicy.ringingResolution(state) == nil, "Missing, ringing, or transitional status keeps Watch available for answer")
}
let first = UUID(), second = UUID()
check(!WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: second, callbackUUID: first), "Old media callback cannot affect new call")
check(!WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: nil, callbackUUID: first), "Retired callback ignored")
check(WatchReliabilityPolicy.acceptsMediaCallback(currentUUID: first, callbackUUID: first), "Current callback accepted")
let now = Date(timeIntervalSince1970: 1_000)
var delivery = WatchEndDelivery(callID: "A", uuid: first)
check(!delivery.shouldDismiss(at: now.addingTimeInterval(600)), "Unsent command cannot expire as success")
for _ in 0..<10 {
    delivery.record(callID: "A", uuid: first, accepted: false, now: now)
    check(!delivery.shouldDismiss(at: now.addingTimeInterval(600)), "Errors persist")
    check(!delivery.text.contains("安卓已确认"), "Never claim Android ended from delivery status")
}
delivery.record(callID: "B", uuid: first, accepted: true, now: now)
check(delivery.acknowledgedAt == nil, "Wrong call cannot acknowledge delivery")
delivery.record(callID: "A", uuid: second, accepted: true, now: now)
check(delivery.acknowledgedAt == nil, "Wrong UUID cannot acknowledge delivery")
delivery.record(callID: "A", uuid: first, accepted: true, now: now)
check(delivery.text == "iPhone 已接收挂断请求", "Use only the existing iPhone acknowledgement")
check(!delivery.shouldDismiss(at: now.addingTimeInterval(4.999)), "Do not hide early")
check(delivery.shouldDismiss(at: now.addingTimeInterval(5)), "Hide acknowledgement after five seconds")
delivery.record(callID: "A", uuid: first, accepted: false, now: now.addingTimeInterval(6))
check(delivery.acknowledgedAt == now && !delivery.failed, "Late delivery failure cannot undo accepted reply")
for mediaFirst in [true, false] {
    var readiness = WatchAnswerReadiness()
    readiness.begin(uuid: first)
    if mediaFirst { readiness.noteMediaReady(uuid: first) }
    else { readiness.noteAndroidActive(uuid: first) }
    check(!readiness.isActive(uuid: first), "Both Android and media are required")
    if mediaFirst { readiness.noteAndroidActive(uuid: first) }
    else { readiness.noteMediaReady(uuid: first) }
    check(readiness.isActive(uuid: first), "Both event orders must converge")
    readiness.begin(uuid: second)
    check(!readiness.isActive(uuid: second), "New call starts without old readiness")
    readiness.noteAndroidActive(uuid: first)
    readiness.noteMediaReady(uuid: first)
    check(!readiness.isActive(uuid: second), "Old readiness cannot activate new call")
    readiness.noteAndroidActive(uuid: second)
    check(!readiness.isActive(uuid: second), "Answer alone is insufficient")
    readiness.noteMediaReady(uuid: second)
    check(readiness.isActive(uuid: second), "Current readiness activates current call")
    readiness.begin(uuid: nil)
    check(!readiness.isActive(uuid: second), "Ended call cannot remain active")
}
// Rapid sequential calls: never carry readiness or feedback across identities.
var rapid = WatchAnswerReadiness()
for index in 0..<50 {
    let owner = UUID()
    rapid.begin(uuid: owner)
    rapid.noteMediaReady(uuid: owner)
    check(!rapid.isActive(uuid: owner), "Ringback on sequential call \(index)")
    rapid.noteAndroidActive(uuid: first)
    check(!rapid.isActive(uuid: owner), "Stale answer on sequential call \(index)")
    rapid.noteAndroidActive(uuid: owner)
    check(rapid.isActive(uuid: owner), "Real answer on sequential call \(index)")
}


// New companion verification must never expire a delivery ACK as Android success.
var verifying = WatchEndDelivery(callID: "A", uuid: first)
verifying.record(callID: "A", uuid: first, accepted: true, now: now)
verifying.beginVerification()
check(!verifying.shouldDismiss(at: now.addingTimeInterval(60)), "Command ACK is not terminal evidence")
for _ in 0..<10 { verifying.verify(callID: "A", uuid: first, confirmed: false, reachable: false, now: now) }
check(verifying.text.contains("连接异常"), "Unreachable verification remains visible")
verifying.verify(callID: "B", uuid: first, confirmed: true, reachable: true, now: now)
check(verifying.confirmedAt == nil, "Other call cannot confirm")
verifying.verify(callID: "A", uuid: second, confirmed: true, reachable: true, now: now)
check(verifying.confirmedAt == nil, "Other UUID cannot confirm")
verifying.verify(callID: "A", uuid: first, confirmed: true, reachable: true, now: now)
check(verifying.text == "安卓已确认通话结束", "Matching terminal proof settles")
check(!verifying.shouldDismiss(at: now.addingTimeInterval(4.9)), "Keep confirmed result for five seconds")
check(verifying.shouldDismiss(at: now.addingTimeInterval(5)), "Dismiss confirmed result")
// SMS identity and device isolation.
check(WatchSMSPolicy.selected(requested: "foreign", current: "A", paired: ["A"]) == nil, "Never fall back for unpaired requested device")
check(WatchSMSPolicy.selected(requested: nil, current: nil, paired: ["A", "B"]) == nil, "Multi-device inbox needs explicit selection")
check(WatchSMSPolicy.selected(requested: nil, current: nil, paired: ["A"]) == "A", "Single-device default")
check(WatchSMSPolicy.selected(requested: "B", current: "A", paired: ["A", "B"]) == "B", "Explicit SMS selection")
for source in [nil, "A", "B", "foreign"] as [String?] {
    check(WatchSMSPolicy.permits(sourceAgentID: source, selectedAgentID: "A", pairedIDs: ["A", "B"]) == (source == "A"), "SMS source scope")
}
check(!WatchSMSPolicy.permits(sourceAgentID: nil, selectedAgentID: nil, pairedIDs: ["A"]), "Unscoped legacy messages never leak")
let body = String(repeating: "中文👨‍👩‍👧‍👦\n", count: 2_000)
for limit in [0, 1, 2, 3, 4, 16, 180, 20_000] {
    let prefix = WatchSMSPolicy.prefix(body, utf8Limit: limit)
    check(prefix.utf8.count <= limit, "UTF-8 budget respected")
    check(body.hasPrefix(prefix), "Never split grapheme clusters")
}
let smsRow = WatchSMSRow(id: "opaque-hash", agentID: "A", sender: "fixture", preview: "测试", timestamp: now, sim: "SIM 2", outgoing: false, unread: true)
check(!WatchSMSPolicy.matches(smsRow, agentID: "B", id: smsRow.id), "Detail cannot cross devices")
check(!WatchSMSPolicy.matches(smsRow, agentID: "A", id: "other"), "Detail cannot cross messages")
let detail = WatchSMSDetail(row: smsRow, body: WatchSMSPolicy.prefix(body, utf8Limit: 20_000), truncated: true)
let encoded = try JSONEncoder().encode(detail)
check(encoded.count <= WatchSMSPolicy.payloadBudget, "Large SMS detail fits transport budget")
let decodedDetail = try JSONDecoder().decode(WatchSMSDetail.self, from: encoded)
check(decodedDetail == detail, "SMS body, SIM and unread round-trip")
let page = WatchSMSPage(devices: [.init(id: "A", name: "fixture")], selectedAgentID: "A", rows: [smsRow], total: 1, generatedAt: now)
let pageData = try JSONEncoder().encode(page)
let decodedPage = try JSONDecoder().decode(WatchSMSPage.self, from: pageData)
check(decodedPage == page, "SMS list round-trip")
// Simulate timeout and duplicate replies against the actual RPC gate.
let gateLock = NSLock()
var callbacks = 0
let gate = WatchReplyGate { _ in gateLock.lock(); callbacks += 1; gateLock.unlock() }
DispatchQueue.concurrentPerform(iterations: 100) { _ in gate.finish(.success(["ok": true])) }
check(callbacks == 1, "Concurrent repeated replies must resume exactly once")
var lateSuccess = false
let timeoutGate = WatchReplyGate { result in if case .success = result { lateSuccess = true } }
timeoutGate.finish(.failure(NSError(domain: "test", code: 1)))
timeoutGate.finish(.success(["ok": true]))
check(!lateSuccess, "Late reply after timeout cannot change result")
let escapedBody = String(repeating: "\u{0000}\\\n\"", count: 10_000)
let boundedEscaped = try WatchSMSPolicy.boundedDetail(row: smsRow, body: escapedBody)
let escapedData = try JSONEncoder().encode(boundedEscaped)
check(escapedData.count <= WatchSMSPolicy.payloadBudget, "JSON escaping cannot overflow the reply budget")
check(boundedEscaped.truncated, "Oversized escaped text must be explicitly marked truncated")
var earlyMirrors = WatchPendingDialMirrors()
let activeA = WatchCallPayload(callID: "A", callUUID: first, phase: .active, number: nil, callerName: nil, updatedAt: now)
let activeB = WatchCallPayload(callID: "B", callUUID: second, phase: .active, number: nil, callerName: nil, updatedAt: now.addingTimeInterval(1))
earlyMirrors.store(activeA); earlyMirrors.store(activeB)
check(earlyMirrors.consume(uuid: first) == activeA, "Another call's early answer cannot overwrite the pending dial")
check(earlyMirrors.count == 0, "Consumed dial buffer must clear other stale mirrors")
for index in 0..<20 {
    earlyMirrors.store(WatchCallPayload(callID: "fixture", callUUID: UUID(), phase: .active, number: nil, callerName: nil, updatedAt: now.addingTimeInterval(Double(index))))
}
check(earlyMirrors.count == 8, "Early answer buffer must be bounded")
earlyMirrors.reset(); check(earlyMirrors.count == 0, "New dial clears old mirrors")
var startupPCM = WatchInitialPCMBuffer()
startupPCM.append(Data(repeating: 1, count: 320))
check(startupPCM.count == 0, "No startup audio accepted outside a session")
startupPCM.begin()
let firstPCM = Data(repeating: 1, count: 320), secondPCM = Data(repeating: 2, count: 320)
startupPCM.append(firstPCM); startupPCM.append(secondPCM)
check(startupPCM.drain() == firstPCM + secondPCM, "Early audio order must survive engine startup")
startupPCM.append(firstPCM)
check(startupPCM.count == 0, "No extra buffering after playback starts")
startupPCM.begin()
for _ in 0..<100 { startupPCM.append(firstPCM) }
check(startupPCM.count == WatchInitialPCMBuffer.capacity, "Startup audio memory and latency are bounded")
startupPCM.discard(); check(startupPCM.drain().isEmpty, "Hangup cannot leak startup audio")
startupPCM.begin(); startupPCM.append(Data([1]))
check(startupPCM.count == 0, "Malformed partial samples cannot corrupt buffered PCM")
for digit in ["0", "1", "9", "*", "#"] { check(WatchDTMFPolicy.validDigit(digit), "Valid DTMF digit") }
for digit in ["", "12", "A", "１", "😀", " ", "+"] { check(!WatchDTMFPolicy.validDigit(digit), "Invalid DTMF digit") }
check(WatchDTMFPolicy.canSend(phase: "active", backendID: "A", expectedID: "A"), "DTMF targets a connected exact call")
check(!WatchDTMFPolicy.canSend(phase: "incoming", backendID: "A", expectedID: "A"), "No early DTMF")
check(!WatchDTMFPolicy.canSend(phase: "ended", backendID: "A", expectedID: "A"), "No DTMF after hangup")
check(!WatchDTMFPolicy.canSend(phase: "active", backendID: "B", expectedID: "A"), "No DTMF to another call")
check(!WatchDTMFPolicy.canSend(phase: "active", backendID: "", expectedID: ""), "No unscoped DTMF")
let mirroredActive = WatchCallPayload(callID: "phone-mirror", callUUID: first, phase: .active, number: nil, callerName: nil, updatedAt: now)
let mirroredEnded = WatchCallPayload(callID: "phone-mirror", callUUID: first, phase: .ended, number: nil, callerName: nil, updatedAt: now.addingTimeInterval(-1))
let otherEnded = WatchCallPayload(callID: "phone-mirror", callUUID: second, phase: .ended, number: nil, callerName: nil, updatedAt: now)
check(WatchCallMirrorPolicy.isTombstoned(mirroredActive, endedCallIDs: [], endedCallUUIDs: [first]), "Active phone mirror can suppress late incoming pushes")
check(WatchCallMirrorPolicy.acceptsTerminalForDisplay(mirroredEnded, current: mirroredActive), "Matching terminal still clears an active tombstoned mirror")
check(!WatchCallMirrorPolicy.acceptsTerminalForDisplay(otherEnded, current: mirroredActive), "Different UUID terminal cannot clear the current display")
check(!WatchCallMirrorPolicy.acceptsTerminalForDisplay(mirroredActive, current: mirroredEnded), "Late active mirror is never a terminal exception")
var immediateCheck = WatchEndDelivery(callID: "fixture", uuid: first)
immediateCheck.beginVerification()
check(immediateCheck.text != "正在向 iPhone 发送挂断请求", "End confirmation starts without waiting forever for an RPC reply")
immediateCheck.record(callID: "fixture", uuid: first, accepted: true, now: now)
immediateCheck.useLegacyAcknowledgement()
check(immediateCheck.shouldDismiss(at: now.addingTimeInterval(6)), "Legacy acknowledgement can still dismiss")
func threadRow(_ id: String, _ device: String, _ sender: String, _ outgoing: Bool, _ offset: Double, _ sim: String) -> WatchSMSRow {
    WatchSMSRow(id: id, agentID: device, sender: sender, preview: id, timestamp: now.addingTimeInterval(offset), sim: sim, outgoing: outgoing, unread: !outgoing)
}
let threadRows = [threadRow("in", "A", "+86 13800138000", false, 0, "SIM 1"), threadRow("out", "A", "13800138000", true, 1, "SIM 2"), threadRow("other", "B", "13800138000", false, 2, "SIM 1")]
let threadGroups = WatchSMSConversationPolicy.groups(threadRows)
check(threadGroups.count == 2, "Same peer across devices must stay separate")
let mergedThread = threadGroups.first { $0.agentID == "A" }!
check(mergedThread.rows.map(\.id) == ["in", "out"], "Both directions merge chronologically")
check(mergedThread.rows.map(\.sim) == ["SIM 1", "SIM 2"], "SIM remains a per-message fact")
check(mergedThread.unreadCount == 1, "Only incoming unread messages count")
check(WatchSMSConversationPolicy.peer("0086 13800138000") == WatchSMSConversationPolicy.peer("13800138000"), "Chinese country prefix normalization")
check(WatchSMSConversationPolicy.peer("+1 555") != WatchSMSConversationPolicy.peer("555"), "Do not guess another country's local identity")
check(WatchSMSConversationPolicy.peer("Bank123") != WatchSMSConversationPolicy.peer("123"), "Alphanumeric sender cannot collapse into digits")
check(WatchSMSConversationPolicy.groups([threadRow("x", "A", "", false, 0, "SIM 1"), threadRow("y", "A", "", false, 1, "SIM 1")]).count == 2, "Unknown senders must not be merged")
check(WatchSMSConversationPolicy.replyNumber("+86 138-0013-8000") == "+8613800138000", "SMS recipient preserves country code")
check(WatchSMSConversationPolicy.replyNumber("Bank123") == nil, "Do not reply to a sender name")
check(WatchSMSConversationPolicy.replyNumber("86+123") == nil, "Reject misplaced country prefix")

if CommandLine.arguments.count > 1 {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let vector = try JSONSerialization.jsonObject(with: data) as! [String: String]
    let root = Data((0..<32).map(UInt8.init))
    func mac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    let control = mac(root, "AirSIM/watch-call-only/v2")
    let grant = vector["grant"]!
    let media = mac(control, "watch-media-v2\n" + grant)
    check(hex(control) == vector["control_hex"], "Cross-language control key")
    check(hex(media) == vector["media_hex"], "Cross-language media key")
    check(b64(mac(media, vector["pcm_canonical"]!)) == vector["pcm_signature"], "Cross-language PCM proof")
    check(b64(mac(control, "watch-response-v2\nfixture-nonce\n200\n" + vector["response_payload"]!)) == vector["response_signature"], "Cross-language response proof")
    let incoming = try WatchVoIPCall(userInfo: ["event": "incoming_call", "agent_id": "agent-fixture",
        "call_id": "call-A", "call_uuid": "11111111-1111-4111-8111-111111111111", "generation": 7])
    check(WatchMediaGrantPolicy.valid(grant, call: incoming, now: 1800000000), "Exact grant accepted")
    check(!WatchMediaGrantPolicy.valid(grant, call: incoming, now: 1800000060), "Expired grant rejected")
    let original = try JSONSerialization.jsonObject(with: WatchMediaGrantPolicy.decode(grant)!) as! [String: Any]
    for field in ["agent_id", "call_id", "call_uuid", "generation", "owner", "session", "expires_at", "session_until"] {
        var tampered = original; tampered[field] = "wrong"
        let encoded = b64(try JSONSerialization.data(withJSONObject: tampered))
        check(!WatchMediaGrantPolicy.valid(encoded, call: incoming, now: 1800000000), "Reject wrong grant field " + field)
    }
}

var dispatchLedger: [String: Double] = [:]
let dispatchID = UUID().uuidString
check(WatchSMSDispatchPolicy.reserve(dispatchID, now: 1000, ledger: &dispatchLedger), "First SMS intent dispatches")
check(!WatchSMSDispatchPolicy.reserve(dispatchID, now: 1001, ledger: &dispatchLedger), "Repeated WC callback cannot resend SMS")
dispatchLedger = try JSONDecoder().decode([String: Double].self, from: JSONEncoder().encode(dispatchLedger))
check(!WatchSMSDispatchPolicy.reserve(dispatchID, now: 1002, ledger: &dispatchLedger), "Lost ACK after restart cannot resend SMS")
check(WatchSMSDispatchPolicy.reserve(UUID().uuidString, now: 1003, ledger: &dispatchLedger), "Explicit new intent may send")
check(!WatchSMSDispatchPolicy.reserve("invalid", now: 1003, ledger: &dispatchLedger), "Missing intent rejected")
let endpointSecret = Data(repeating: 1, count: 32).base64EncodedString()
for host in ["100.64.0.1", "100.127.255.254", "192.168.1.2", "169.254.1.2"] {
    check(WatchLocalPCMEndpoint(dictionary: ["pcm_host": host, "pcm_port": 7593, "pcm_secret": endpointSecret]) != nil, "Private VPN host allowed " + host)
}
for host in ["100.128.0.1", "8.8.8.8", "010.1.1.1", "192.168.001.2"] {
    check(WatchLocalPCMEndpoint(dictionary: ["pcm_host": host, "pcm_port": 7593, "pcm_secret": endpointSecret]) == nil, "Public or ambiguous host rejected " + host)
}

check(WatchReliabilityPolicy.incomingDisposition(currentUUID: first, incomingUUID: first, retired: false) == .duplicate, "Mirror then push preserves same call")
check(WatchReliabilityPolicy.incomingDisposition(currentUUID: first, incomingUUID: second, retired: false) == .busy, "Second incoming cannot overwrite active call")
check(WatchReliabilityPolicy.incomingDisposition(currentUUID: first, incomingUUID: second, retired: true) == .busy, "Old push cannot clear current call")
check(WatchReliabilityPolicy.incomingDisposition(currentUUID: nil, incomingUUID: second, retired: true) == .retired, "Retired incoming does not ring again")
check(WatchReliabilityPolicy.incomingDisposition(currentUUID: nil, incomingUUID: second, retired: false) == .newCall, "New incoming still reports")
// Execute the production async end verifier with dropped replies and delayed state.
do {
    var sends = 0, reads = 0
    let confirmed = await WatchDirectEndVerifier.verify(isCurrent: { true }, hangup: {
        sends += 1; throw URLError(.timedOut)
    }, status: { reads += 1; return reads >= 2 ? "ended" : "active" }, pause: {})
    check(confirmed && sends == 1, "Lost ACK plus confirmed terminal never sends a second end")
    sends = 0
    let failed = await WatchDirectEndVerifier.verify(isCurrent: { true }, hangup: { sends += 1 },
        status: { throw URLError(.timedOut) }, pause: {})
    check(!failed && sends == 3, "Unknown status is bounded and never claimed ended")
    sends = 0
    let unknown = await WatchDirectEndVerifier.verify(isCurrent: { true }, hangup: { sends += 1 },
        status: { "unknown" }, pause: {})
    check(!unknown && sends == 0, "Unrecognized signed state cannot authorize a hangup")
    var current = true
    let replaced = await WatchDirectEndVerifier.verify(isCurrent: { current }, hangup: { sends += 1 },
        status: { current = false; return "active" }, pause: {})
    check(!replaced && sends == 0, "A late status cannot hang up after another call takes ownership")
    let already = await WatchDirectEndVerifier.verify(isCurrent: { true }, hangup: { sends += 1 },
        status: { "ended" }, pause: {})
    check(already && sends == 0, "Repeated terminal requires no write")
    sends = 0; reads = 0
    let delayed = await WatchDirectEndVerifier.verify(isCurrent: { true }, hangup: { sends += 1 },
        status: { reads += 1; return reads >= 4 ? "ended" : "active" }, pause: {})
    check(delayed && sends == 2, "Delayed carrier hangup retries only the same scoped request")
}
print("Watch reliability checks passed: \(assertionCount) assertions")
