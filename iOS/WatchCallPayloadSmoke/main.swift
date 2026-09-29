import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
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
