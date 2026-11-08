import Foundation

@MainActor
protocol VoBLECallControlling: AnyObject {
    var state: VoBLEConnectionState { get }
    var onEvent: ((VoBLEAndroidEvent) -> Void)? { get set }
    var onAudioDownlinkFragment: ((Data) -> Void)? { get set }
    var onReadyToSendAudio: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    func send(command: String, callID: String, generation: UInt64,
              number: String) async throws -> VoBLEControlResponse
    func send(command: String, callID: String, generation: UInt64,
              number: String, simAccount: String?) async throws -> VoBLEControlResponse
    func mediaKey(callID: String, generation: UInt64) throws -> Data
    func synchronizeCallGeneration() async throws -> UInt64
}

extension VoBLECallControlling {
    func synchronizeCallGeneration() async throws -> UInt64 { 0 }
    func send(command: String, callID: String, generation: UInt64,
              number: String, simAccount: String?) async throws -> VoBLEControlResponse {
        try await send(command: command, callID: callID, generation: generation, number: number)
    }
}

extension VoBLECentralController: VoBLECallControlling {}

struct VoBLECallIdentity: Equatable, Sendable {
    let callID: String
    let generation: UInt64
    let uuid: UUID
    let direction: String
    let number: String?
    let isProvisional: Bool

    var mediaIdentity: VoBLEMediaSessionIdentity {
        .init(callID: callID, generation: generation)
    }
}

enum VoBLECallTransition: Equatable, Sendable {
    case ignored
    case incoming(VoBLECallIdentity)
    case connecting(VoBLECallIdentity)
    case active(VoBLECallIdentity, startMedia: Bool)
    case ended(VoBLECallIdentity)
}

/// Generation is the ownership boundary. A delayed event from a previous call must never
/// stop audio or CallKit for the current call.
struct VoBLECallLifecycleReducer: Sendable {
    private(set) var current: VoBLECallIdentity?
    private(set) var mediaRequested = false
    private var terminalKeys: Set<String> = []

    mutating func beginOutgoing(callID: String, generation: UInt64, number: String, uuid: UUID = UUID()) -> VoBLECallIdentity {
        let value = VoBLECallIdentity(
            callID: callID, generation: generation, uuid: uuid,
            direction: "outgoing", number: number, isProvisional: true)
        current = value
        mediaRequested = false
        return value
    }

    mutating func apply(_ event: VoBLEAndroidEvent) -> VoBLECallTransition {
        guard !event.callID.isEmpty, event.generation > 0 else { return .ignored }
        let key = "\(event.callID):\(event.generation)"
        if terminalKeys.contains(key) { return .ignored }

        if event.state == "ended" {
            guard let current,
                  current.callID == event.callID,
                  current.generation == event.generation else { return .ignored }
            terminalKeys.insert(key)
            self.current = nil
            mediaRequested = false
            return .ended(current)
        }

        let identity: VoBLECallIdentity
        if let current, current.generation == event.generation {
            if current.callID != event.callID, !(current.direction == "outgoing" && current.isProvisional) { return .ignored }
            // Android assigns the authoritative Telecom call ID after an outgoing dial.
            identity = VoBLECallIdentity(
                callID: event.callID, generation: event.generation, uuid: current.uuid,
                direction: event.direction.isEmpty ? current.direction : event.direction,
                number: event.number.isEmpty ? current.number : event.number,
                isProvisional: false)
        } else {
            guard current == nil || event.generation > current!.generation else { return .ignored }
            identity = VoBLECallIdentity(
                callID: event.callID, generation: event.generation, uuid: UUID(),
                direction: event.direction, number: event.number.isEmpty ? nil : event.number,
                isProvisional: false)
            mediaRequested = false
        }
        current = identity

        switch event.state {
        case "incoming", "waiting": return .incoming(identity)
        case "active", "held":
            let shouldStart = !mediaRequested
            mediaRequested = true
            return .active(identity, startMedia: shouldStart)
        case "dialing", "connecting": return mediaRequested ? .ignored : .connecting(identity)
        default: return .ignored
        }
    }

    mutating func resetIfMatching(_ identity: VoBLECallIdentity) -> Bool {
        guard current == identity else { return false }
        current = nil
        mediaRequested = false
        return true
    }

    func hasEnded(_ identity: VoBLECallIdentity) -> Bool {
        terminalKeys.contains("\(identity.callID):\(identity.generation)")
    }
}

@MainActor
final class VoBLECallCoordinator {
    var onIncoming: ((IncomingVoIPCall) -> Void)?
    var onState: ((VoBLECallIdentity, CallLifecycleState) -> Void)?
    var onEnded: ((VoBLECallIdentity) -> Void)?
    var onError: ((String) -> Void)?
    var audioSessionContext: () -> (managedByCallKit: Bool, active: Bool) = { (true, false) }
    var mediaPermission: (VoBLECallIdentity) -> Bool = { _ in true }
    var onEarlyPlayback: (() -> Void)?
    private(set) var earlyMediaAudible = false
    private(set) var earlyMediaUnavailable = false
    private var carrierEarlyMediaEnabled = true
    private var earlyAttempt: VoBLECallIdentity?
    private var earlyDeadlineTask: Task<Void, Never>?
    private var mediaRequestVersion = 0
    private var endingIdentity: VoBLECallIdentity?
    var onOutgoingIntent: ((VoBLECallIdentity) -> Void)?

    private let central: any VoBLECallControlling
    private let media: VoBLEGATTMediaTransport
    private let audio: VoBLEAudioEngine
    private let defaults: UserDefaults
    private let traceRecorder: AgentVerboseTraceRecorder
    private var reducer = VoBLECallLifecycleReducer()
    private var recoveryTask: Task<Void, Never>?
    private var recoveringIdentity: VoBLECallIdentity?
    private var pendingOutgoing: (callID: String, token: UUID)?
    private var mediaStartAttempts = 0
    private var mediaStartIdentity: VoBLECallIdentity?
    private let generationKey = "airsim.voble.call-generation"

    init(
        central: any VoBLECallControlling,
        media: VoBLEGATTMediaTransport,
        audio: VoBLEAudioEngine,
        defaults: UserDefaults = .standard,
        traceRecorder: AgentVerboseTraceRecorder = .shared
    ) {
        self.central = central
        self.media = media
        self.audio = audio
        self.defaults = defaults
        self.traceRecorder = traceRecorder
        audio.onEarlyPlayback = { [weak self] in
            guard let self, !self.earlyMediaAudible, self.audio.receiveOnly, !self.reducer.mediaRequested,
                  let identity = self.reducer.current, self.mediaPermission(identity) else { return }
            self.earlyMediaAudible = true
            self.onEarlyPlayback?()
        }
        central.onEvent = { [weak self] event in self?.receive(event) }
        central.onAudioDownlinkFragment = { [weak media] fragment in
            media?.receiveDownlinkFragment(fragment)
        }
        central.onReadyToSendAudio = { [weak media] in media?.peripheralIsReadyToSend() }
        central.onDisconnected = { [weak self] in self?.disconnect() }
        central.onReady = { [weak self] in self?.resumeAfterReconnect() }
    }

    var currentIdentity: VoBLECallIdentity? { reducer.current }
    var isReady: Bool { central.state == .ready }

    func cancelPendingOutgoing(callID: String) -> Bool {
        guard pendingOutgoing?.callID == callID else { return false }
        pendingOutgoing = nil
        return true
    }

    func startOutgoing(number: String, operationID: String? = nil, systemUUID: UUID? = nil,
                       simAccount: String? = nil) async throws -> VoBLECallIdentity {
        guard pendingOutgoing == nil, reducer.current == nil else { throw VoBLECentralError.bluetooth("call_in_progress") }
        carrierEarlyMediaEnabled = CarrierRingbackPreference.isEnabled()
        let provisionalID = operationID ?? UUID().uuidString.lowercased()
        let token = UUID()
        pendingOutgoing = (provisionalID, token)
        defer { if pendingOutgoing?.token == token { pendingOutgoing = nil } }
        var identity: VoBLECallIdentity?
        var phase = "generation_sync"
        do {
            let floor = try await central.synchronizeCallGeneration()
            guard !Task.isCancelled, pendingOutgoing?.token == token, reducer.current == nil else {
                throw CancellationError()
            }
            let stored = UInt64(max(0, defaults.integer(forKey: generationKey)))
            let previous = max(stored, floor)
            guard previous < UInt64(Int.max) else { throw VoBLECentralError.invalidResponse }
            let generation = previous + 1
            defaults.set(Int(generation), forKey: generationKey)
            await traceRecorder.recordEvent(source: "APP", category: "voble", phase: "generation_sync",
                title: "蓝牙拨号序号已同步", fields: ["peer_floor": String(floor), "generation": String(generation)])
            // Keep the cancellable reservation across every pre-dial await,
            // including diagnostics; a completed hangup must never dial later.
            guard !Task.isCancelled, pendingOutgoing?.token == token, reducer.current == nil else {
                throw CancellationError()
            }
            pendingOutgoing = nil
            let outgoing = reducer.beginOutgoing(callID: provisionalID, generation: generation,
                number: number, uuid: systemUUID ?? UUID())
            identity = outgoing
            onOutgoingIntent?(outgoing)
            phase = "dial_command"
            let response = try await central.send(
                command: "dial", callID: provisionalID,
                generation: generation, number: number, simAccount: simAccount)
            guard response.success else {
                throw VoBLECentralError.bluetooth(response.detail.isEmpty ? response.code : response.detail)
            }
            await traceRecorder.recordEvent(source: "APP", category: "voble", phase: "dial_reply",
                title: "蓝牙拨号已接受", fields: ["generation": String(generation), "success": "true"])
            // Telecom events may arrive before the dial response. Never restore
            // the provisional ID or regress an already active call to connecting.
            guard let current = reducer.current, current.generation == generation else {
                throw CancellationError()
            }
            if current.isProvisional { onState?(current, .connecting) }
            return current
        } catch {
            let wasPending = pendingOutgoing?.token == token
            let reset = identity.map { reducer.resetIfMatching($0) } ?? false
            if (reset || wasPending), !(error is CancellationError) {
                // Router rollback may already retire CallKit's UUID, making the
                // later provider callback stale. Keep this exact failure visible.
                onError?(error.localizedDescription)
            }
            if !(error is CancellationError) {
                await traceRecorder.recordFailure(category: "voble", phase: phase, error: error)
            }
            throw error
        }
    }

    func answer() async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        try await requireSuccess("answer", identity: identity)
        onState?(identity, .connecting)
    }

    func end(rejectIfRinging: Bool) async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        endingIdentity = identity
        earlyDeadlineTask?.cancel(); earlyDeadlineTask = nil
        mediaRequestVersion += 1; earlyMediaAudible = false
        audio.stop(); media.stop(identity: identity.mediaIdentity)
        do {
            try await requireSuccess(rejectIfRinging ? "reject" : "end", identity: identity)
        } catch {
            // The authenticated terminal event is authoritative even if an
            // older Android build rejects the later command as call_mismatch.
            guard reducer.hasEnded(identity) else { throw error }
#if DEBUG
            print("[AirSIM VoBLE Call] end acknowledged by terminal event")
#endif
            return
        }
        // An ended event or a newer call can win while awaiting the reply.
        // Never resurrect the old call or overwrite the replacement's state.
        guard reducer.current == identity else { return }
        onState?(identity, .ending)
    }

    func sendDTMF(_ digits: String) async throws {
        guard let identity = reducer.current else { throw VoBLECentralError.invalidResponse }
        for digit in digits where "0123456789*#".contains(digit) {
            let response = try await central.send(
                command: "dtmf", callID: identity.callID,
                generation: identity.generation, number: String(digit))
            guard response.success else { throw VoBLECentralError.bluetooth(response.code) }
        }
    }

    func setMuted(_ muted: Bool) { audio.setMuted(muted) }
    func setCallKitAudioActive(_ active: Bool) { audio.setCallKitAudioActive(active) }

    func disconnect() {
        earlyDeadlineTask?.cancel(); earlyDeadlineTask = nil
        mediaRequestVersion += 1; earlyMediaAudible = false
        pendingOutgoing = nil
        guard let identity = reducer.current, recoveringIdentity == nil else { return }
        audio.setMediaReady(false)
        media.stop(identity: identity.mediaIdentity)
        recoveringIdentity = identity
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.failRecovery(identity)
        }
    }

    private func stopEarlyMedia(_ identity: VoBLECallIdentity) {
        guard reducer.current == identity, !reducer.mediaRequested else { return }
        mediaRequestVersion += 1
        earlyDeadlineTask?.cancel(); earlyDeadlineTask = nil
        earlyMediaAudible = false; earlyMediaUnavailable = true
        audio.stop(); media.stop(identity: identity.mediaIdentity)
    }

    private func receive(_ event: VoBLEAndroidEvent) {
        if event.state == "early_media_stopped" {
            if let identity = reducer.current, identity.callID == event.callID,
               identity.generation == event.generation { stopEarlyMedia(identity) }
            return
        }
#if DEBUG
        print("[AirSIM VoBLE Call] event state=\(event.state) generation=\(event.generation)")
#endif
        if let recoveringIdentity, event.generation != recoveringIdentity.generation { return }
        if let endingIdentity, event.callID == endingIdentity.callID,
           event.generation == endingIdentity.generation, event.state != "ended" { return }
        defaults.set(Int(max(event.generation, UInt64(max(0, defaults.integer(forKey: generationKey))))),
                     forKey: generationKey)
        switch reducer.apply(event) {
        case .ignored: return
        case let .incoming(identity):
            onIncoming?(IncomingVoIPCall(
                bluetoothCallID: identity.callID, uuid: identity.uuid,
                generation: identity.generation, number: identity.number))
            onState?(identity, .ringing)
        case let .connecting(identity):
            onState?(identity, .connecting)
            if CarrierRingbackPreference.allowsReceiveOnly(enabled: carrierEarlyMediaEnabled,
                outgoing: identity.direction == "outgoing", state: .connecting),
               event.state == "dialing", earlyAttempt != identity {
                earlyMediaUnavailable = false
                earlyAttempt = identity
                Task { await startMedia(for: identity, receiveOnly: true) }
            }
        case let .active(identity, shouldStartMedia):
            earlyMediaAudible = false
            onState?(identity, .active)
            if shouldStartMedia { Task { await startMedia(for: identity) } }
        case let .ended(identity):
            earlyDeadlineTask?.cancel(); earlyDeadlineTask = nil
            mediaRequestVersion += 1; earlyMediaAudible = false; earlyAttempt = nil
            audio.stop()
            media.stop(identity: identity.mediaIdentity)
            onEnded?(identity)
        }
    }

    private func resumeAfterReconnect() {
        guard let identity = recoveringIdentity,
              reducer.current == identity else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveringIdentity = nil
        Task { await startMedia(for: identity, receiveOnly: !reducer.mediaRequested) }
    }

    private func failRecovery(_ identity: VoBLECallIdentity) {
        guard recoveringIdentity == identity else { return }
        recoveringIdentity = nil
        recoveryTask = nil
        guard reducer.resetIfMatching(identity) else { return }
        audio.stop()
        onEnded?(identity)
    }

    private func startMedia(for identity: VoBLECallIdentity, receiveOnly: Bool = false) async {
        guard !receiveOnly || carrierEarlyMediaEnabled else { return }
        guard endingIdentity != identity, reducer.current == identity, reducer.mediaRequested != receiveOnly,
              !receiveOnly || (identity.direction == "outgoing" && !identity.isProvisional) else { return }
        mediaRequestVersion += 1
        earlyDeadlineTask?.cancel(); earlyDeadlineTask = nil
        let version = mediaRequestVersion
        let nonce = UUID().uuidString.lowercased()
        audio.setMediaReady(false)
        media.stop(identity: identity.mediaIdentity)
        if mediaStartIdentity != identity {
            mediaStartIdentity = identity
            mediaStartAttempts = 0
        }
        let permitted = mediaPermission(identity), matches = reducer.current == identity
        Task { await AgentVerboseTraceRecorder.shared.recordEvent(source: "ios", category: "voble",
            phase: "media_admission", title: "蓝牙媒体归属检查",
            fields: ["permitted": String(permitted), "identity_current": String(matches),
                     "generation": String(identity.generation)], isFailure: !permitted || !matches) }
        guard permitted, matches else { return }
        do {
            let context = audioSessionContext()
            try await audio.prepareForCall(
                managedByCallKit: context.managedByCallKit,
                callKitAudioActive: context.active, receiveOnly: receiveOnly)
            guard mediaRequestVersion == version, reducer.current == identity, reducer.mediaRequested != receiveOnly, mediaPermission(identity) else {
                if reducer.current == nil { audio.stop() }
                return
            }
            // Permission prompts can yield while CallKit activates its session.
            audio.setCallKitAudioActive(audioSessionContext().active)
            let response = try await central.send(
                command: receiveOnly ? "start_early_media" : "start_media", callID: identity.callID,
                generation: identity.generation, number: receiveOnly ? nonce : "")
            guard mediaRequestVersion == version, reducer.current == identity, reducer.mediaRequested != receiveOnly else { return }
            guard response.success, response.detail == (receiveOnly ? "early_media_ready_v1" : "media_ready"),
                  mediaPermission(identity) else {
                throw VoBLECentralError.bluetooth(
                    response.detail.isEmpty ? response.code : response.detail)
            }
            let key = try central.mediaKey(callID: identity.callID, generation: identity.generation)
            try media.start(identity: identity.mediaIdentity,
                            mediaKey: receiveOnly ? VoBLEGATTMediaTransport.earlyMediaKey(key, nonce: nonce) : key,
                            receiveOnly: receiveOnly)
            audio.setMediaReady(true)
            if receiveOnly {
                earlyDeadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled, let self, self.mediaRequestVersion == version else { return }
                    self.stopEarlyMedia(identity)
                }
            }
            mediaStartAttempts = 0
        } catch {
            guard mediaRequestVersion == version, reducer.current == identity else { return }
            if receiveOnly {
                // Old agents reject the optional command. Keep waiting for Telecom;
                // never retry dial, manufacture ACTIVE, or acquire a microphone.
                audio.stop()
                earlyMediaUnavailable = true
                await traceRecorder.recordEvent(source: "APP", category: "voble", phase: "early_media_unavailable",
                    title: "此设备暂未提供接通前运营商音频", fields: [:])
                return
            }
            await AgentVerboseTraceRecorder.shared.recordFailure(category: "voble", phase: "start_media", error: error)
            onError?(error.localizedDescription)
            // Only retry failures that prove the command never reached a ready
            // peer. A protocol rejection or timeout is ambiguous and retrying
            // start_media could double-start the Android media session.
            let retryable: Bool
            switch error {
            case VoBLECentralError.disconnected, VoBLECentralError.notReady: retryable = true
            default: retryable = false
            }
            guard retryable, mediaStartAttempts == 0,
                  reducer.current == identity, mediaPermission(identity) else { return }
            mediaStartAttempts = 1
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, reducer.current == identity else { return }
            await startMedia(for: identity)
        }
    }

    private func requireSuccess(_ command: String, identity: VoBLECallIdentity) async throws {
#if DEBUG
        print("[AirSIM VoBLE Call] command=\(command) generation=\(identity.generation)")
#endif
        let response = try await central.send(
            command: command, callID: identity.callID, generation: identity.generation, number: "")
#if DEBUG
        print("[AirSIM VoBLE Call] response command=\(command) success=\(response.success) code=\(response.code)")
#endif
        guard response.success else {
            throw VoBLECentralError.bluetooth(response.detail.isEmpty ? response.code : response.detail)
        }
    }
}
