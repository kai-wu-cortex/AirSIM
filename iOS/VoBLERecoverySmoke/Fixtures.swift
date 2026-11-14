import Foundation

enum CallTransport { case bluetooth, vowlan, cloud }
enum VoBLEConnectionState { case ready }
enum VoBLECentralError: Error { case bluetooth(String), invalidResponse, disconnected, notReady }
struct IncomingVoIPCall {
    let callID: String, uuid: UUID, generation: UInt64, number: String?, agentID: String?
    init(bluetoothCallID: String, uuid: UUID, generation: UInt64, number: String?, agentID: String? = nil) {
        callID = bluetoothCallID; self.uuid = uuid; self.generation = generation
        self.number = number; self.agentID = agentID
    }
}
struct VoBLEMediaSessionIdentity: Equatable { let callID: String; let generation: UInt64 }
enum CarrierRingbackPreference {
    static func isEnabled() -> Bool { true }
    static func allowsReceiveOnly(enabled: Bool, outgoing: Bool, state: CallLifecycleState) -> Bool {
        enabled && outgoing && state == .connecting
    }
}
actor AgentVerboseTraceRecorder {
    static let shared = AgentVerboseTraceRecorder()
    func recordEvent(source: String, category: String, phase: String, title: String,
                     fields: [String: String], isFailure: Bool = false) {}
    func recordFailure(category: String, phase: String, error: Error) {}
}
@MainActor final class VoBLEGATTMediaTransport {
    var running = false
    var earlyKeepalive = false
    func receiveDownlinkFragment(_ data: Data) {}
    func peripheralIsReadyToSend() {}
    func stop(identity: VoBLEMediaSessionIdentity) { running = false }
    func start(identity: VoBLEMediaSessionIdentity, mediaKey: Data, receiveOnly: Bool = false, earlyKeepalive: Bool = false) throws { running = true; self.earlyKeepalive = earlyKeepalive }
    static func earlyMediaKey(_ key: Data, nonce: String) -> Data { key }
}
@MainActor final class VoBLEAudioEngine {
    var onEarlyPlayback: (() -> Void)?
    var receiveOnly = false
    func setMediaReady(_ ready: Bool) {}
    func setCallKitAudioActive(_ active: Bool) {}
    func setMuted(_ muted: Bool) {}
    func stop() {}
    func prepareForCall(managedByCallKit: Bool, callKitAudioActive: Bool, receiveOnly: Bool) async throws {
        self.receiveOnly = receiveOnly
    }
}
@MainActor final class Probe: VoBLECallControlling {
    var state: VoBLEConnectionState = .ready
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?
    var commands: [String] = []
    var earlyCount = 0
    var early: (Int) async throws -> String = { _ in "early_media_ready_v1" }
    func mediaKey(callID: String, generation: UInt64) throws -> Data { Data(repeating: 1, count: 32) }
    func send(command: String, callID: String, generation: UInt64, number: String) async throws -> VoBLEControlResponse {
        commands.append(command)
        var detail = "media_ready"
        if command == "start_early_media" { earlyCount += 1; detail = try await early(earlyCount) }
        let success = !detail.hasPrefix("early_media_not_") && detail != "early_media_unavailable"
        return .init(requestID: UUID().uuidString, generation: generation, success: success,
                     code: success ? "ok" : detail, detail: success ? detail : "")
    }
}
