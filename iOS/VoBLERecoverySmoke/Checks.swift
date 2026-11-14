import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        for scenario in 0..<8 {
            let probe = Probe(), media = VoBLEGATTMediaTransport(), audio = VoBLEAudioEngine()
            let suite = "VoBLERecovery.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let calls = VoBLECallCoordinator(central: probe, media: media, audio: audio, defaults: defaults)
            calls.earlyMediaRetryWait = { await Task.yield() }
            var permission = scenario != 1
            calls.mediaPermission = { _ in permission }
            var delayed: CheckedContinuation<String, Never>?
            switch scenario {
            case 0: probe.early = { $0 == 1 ? "early_media_not_ready" : "early_media_ready_v1" }
            case 1: calls.earlyMediaRetryWait = { permission = true }
            case 2: probe.early = { _ in "early_media_unavailable" }
            case 3: probe.early = { _ in throw URLError(.timedOut) }
            case 4: probe.early = { _ in "early_media_not_ready" }
            case 7: probe.early = { _ in "early_media_ready_keepalive_v1" }
            case 5, 6: probe.early = { _ in await withCheckedContinuation { delayed = $0 } }
            default: break
            }
            let outgoing = try await calls.startOutgoing(number: "fixture")
            func event(_ state: String) {
                probe.onEvent?(.init(callID: "carrier", generation: outgoing.generation,
                    direction: "outgoing", state: state, number: "fixture"))
            }
            event("dialing")
            for _ in 0..<500 { await Task.yield() }
            switch scenario {
            case 0: precondition(probe.earlyCount == 2 && media.running && audio.receiveOnly && !media.earlyKeepalive)
            case 1: precondition(probe.earlyCount == 1 && media.running)
            case 7: precondition(media.running && audio.receiveOnly && media.earlyKeepalive)
            case 2, 3: precondition(probe.earlyCount == 1 && !media.running && calls.earlyMediaUnavailable)
            case 4: precondition(probe.earlyCount == 25 && !media.running && calls.earlyMediaUnavailable)
            case 5:
                precondition(delayed != nil)
                event("ended")
                delayed?.resume(returning: "early_media_ready_v1")
                for _ in 0..<100 { await Task.yield() }
                precondition(!media.running && calls.currentIdentity == nil)
            case 6:
                event("active")
                for _ in 0..<100 { await Task.yield() }
                delayed?.resume(returning: "early_media_ready_v1")
                for _ in 0..<100 { await Task.yield() }
                precondition(media.running && !audio.receiveOnly && probe.commands.filter { $0 == "start_media" }.count == 1)
            default: break
            }
            precondition(probe.commands.filter { $0 == "dial" }.count == 1, "media retry must never redial")
            event("ended")
            precondition(!media.running)
        }
        // Exercise the production incoming recovery wait with a monotonic fake
        // clock, including the 16-second cold handshake seen on the phone.
        for scenario in 0..<5 {
            var clock: TimeInterval = 0
            var snapshots = 0
            var resolved = 0
            do {
                let result: String? = try await BluetoothIncomingRecovery.wait(isCurrent: {
                    // Ended/replaced/expired presentations must never be answered.
                    scenario != 2 || clock < 4
                }, resolve: {
                    let ready = scenario == 0 ? clock >= 16 : scenario == 3 ? clock == 0 : false
                    if ready { resolved += 1; return "exact-authenticated-call" }
                    return nil
                }, refresh: { snapshots += 1 }, now: { clock }, sleep: {
                    if scenario == 4 { throw CancellationError() }
                    clock += 0.2
                })
                if scenario == 0 || scenario == 3 {
                    precondition(result != nil && resolved == 1)
                    precondition(scenario != 0 || clock >= 16)
                } else {
                    precondition(scenario == 1 && result == nil && clock >= 35 && clock < 35.3)
                }
            } catch is CancellationError {
                precondition(scenario == 2 || scenario == 4)
                precondition(resolved == 0 && clock < 4.3)
            }
            if scenario == 3 { precondition(snapshots == 0) }
        }
        print("PASS: 5 production incoming recovery cases (cold 16s, timeout, stale, ready, cancellation)")
        let push = IncomingVoIPCall(bluetoothCallID: "call", uuid: UUID(), generation: 1, number: "same", agentID: "A")
        let event = DeviceCallEvent(agentID: "A", callID: "call", state: .ringing, transport: .bluetooth,
                                   transportEpoch: 2, backendGeneration: 7)
        precondition(BluetoothIncomingCallPolicy.matches(push: push, event: event,
            authenticatedAgent: "A", callID: "call", generation: 7, epoch: 2))
        for agent: String? in [nil, "B", ""] {
            precondition(!BluetoothIncomingCallPolicy.matches(push: push, event: event,
                authenticatedAgent: agent, callID: "call", generation: 7, epoch: 2))
        }
        precondition(!BluetoothIncomingCallPolicy.matches(push: push, event: event,
            authenticatedAgent: "A", callID: "other", generation: 7, epoch: 2))
        precondition(!BluetoothIncomingCallPolicy.matches(push: push, event: event,
            authenticatedAgent: "A", callID: "call", generation: 8, epoch: 2))
        precondition(!BluetoothIncomingCallPolicy.matches(push: push, event: event,
            authenticatedAgent: "A", callID: "call", generation: 7, epoch: 3))
        for state: CallLifecycleState in [.active, .ended, .ending] {
            let invalid = DeviceCallEvent(agentID: "A", callID: "call", state: state, transport: .bluetooth,
                                          transportEpoch: 2, backendGeneration: 7)
            precondition(!BluetoothIncomingCallPolicy.matches(push: push, event: invalid,
                authenticatedAgent: "A", callID: "call", generation: 7, epoch: 2))
        }
        print("PASS: 8 production BLE coordinator scenarios; authenticated call identity isolation")
    }
}
