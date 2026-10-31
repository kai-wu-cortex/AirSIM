import Foundation

struct DeviceCallKey: Hashable, Sendable {
    let agentID: String
    let callID: String
    let generation: UInt64
}

struct DeviceCallEvent: Sendable {
    let agentID: String
    let callID: String
    var replacesCallID: String? = nil
    let state: CallLifecycleState
    let transport: CallTransport
    let transportEpoch: UInt64
    var backendGeneration: UInt64? = nil
    var number: String? = nil
    var direction: String = "incoming"
    var backendCallID: String? = nil
}

enum DeviceCallEffect: Equatable, Sendable {
    case present(DeviceCallKey), remind(DeviceCallKey), update(DeviceCallKey)
    case dismiss(DeviceCallKey), ended(DeviceCallKey)
}

struct DeviceCallRegistry: Sendable {
    private struct RawKey: Hashable, Sendable { let agent: String; let call: String }
    private struct Entry: Sendable {
        var event: DeviceCallEvent
        var epochs: [String: UInt64]
        var generations: [String: UInt64]
    }
    private(set) var active: DeviceCallKey?
    private var serial: UInt64 = 0
    private var entries: [DeviceCallKey: Entry] = [:]
    private var aliases: [RawKey: DeviceCallKey] = [:]
    private var order: [DeviceCallKey] = []
    var ringing: [DeviceCallKey] { order.filter { entries[$0]?.event.state == .ringing } }

    mutating func apply(_ event: DeviceCallEvent) -> [DeviceCallEffect] {
        guard !event.agentID.isEmpty, !event.callID.isEmpty, event.state != .idle else { return [] }
        let raw = RawKey(agent: event.agentID, call: event.callID)
        let lane = String(describing: event.transport)
        var key = aliases[raw]
        if let replaces = event.replacesCallID {
            // An alias is proof supplied by this device's authenticated outgoing
            // operation, never a join based on a matching phone number or timing.
            guard let original = aliases[RawKey(agent: event.agentID, call: replaces)],
                  let entry = entries[original], entry.event.direction == "outgoing",
                  entry.event.state == .connecting || (entry.event.state == .ending && event.state.isTerminal),
                  entry.epochs[lane] == event.transportEpoch,
                  entry.generations[lane] == event.backendGeneration,
                  key == nil || key == original else { return [] }
            key = original
        }
        if key == nil {
            serial &+= 1
            key = DeviceCallKey(agentID: event.agentID, callID: event.callID, generation: serial)
        }
        guard let key else { return [] }
        let previous = entries[key]
        if let previous {
            guard event.transportEpoch >= (previous.epochs[lane] ?? 0),
                  (previous.event.state.isTerminal ? event.state.isTerminal
                    : Self.mayAdvance(from: previous.event.state, to: event.state)) else { return [] }
            if let generation = event.backendGeneration,
               let old = previous.generations[lane], generation < old { return [] }
        }
        var entry = previous ?? Entry(event: event, epochs: [:], generations: [:])
        entry.event = event
        entry.epochs[lane] = event.transportEpoch
        entry.generations[lane] = event.backendGeneration
        aliases[raw] = key
        entries[key] = entry
        if previous == nil { order.append(key) }
        if event.state.isTerminal {
            // A second lane may supply the backend alias missing from the first
            // terminal. Refresh its validated metadata without ending twice.
            if previous?.event.state.isTerminal == true { return [] }
            if active == key { active = nil }
            trimTerminalHistory()
            return [.dismiss(key), .ended(key)]
        }
        if previous?.event.state == event.state, previous?.event.callID == event.callID { return [] }
        if event.state == .ringing {
            return active == nil || active == key ? [.present(key)] : [.remind(key)]
        }
        return [.update(key)]
    }

    mutating func activate(_ key: DeviceCallKey) -> Bool {
        guard active == nil || active == key,
              let state = entries[key]?.event.state,
              state.representsCall, state != .ending else { return false }
        active = key
        return true
    }

    /// Release an optimistic answer that the transport rejected. The ringing
    /// event itself must stay in the registry so the user can retry.
    mutating func deactivate(_ key: DeviceCallKey) {
        if active == key { active = nil }
    }

    mutating func finish(_ key: DeviceCallKey) {
        guard var event = entries[key]?.event, !event.state.isTerminal else { return }
        event = DeviceCallEvent(agentID: event.agentID, callID: event.callID, state: .ended,
            transport: event.transport, transportEpoch: event.transportEpoch,
            backendGeneration: event.backendGeneration, number: event.number, direction: event.direction)
        _ = apply(event)
    }

    func latestEvent(for key: DeviceCallKey) -> DeviceCallEvent? { entries[key]?.event }
    func key(agentID: String, callID: String) -> DeviceCallKey? {
        aliases[RawKey(agent: agentID, call: callID)]
    }

    private static func mayAdvance(from: CallLifecycleState, to: CallLifecycleState) -> Bool {
        if from == .ending { return to == .ending || to.isTerminal }
        if from == .active { return to == .active || to == .ending || to.isTerminal }
        if from == .connecting { return to != .ringing }
        return true
    }

    private mutating func trimTerminalHistory() {
        let expired = order.filter { entries[$0]?.event.state.isTerminal == true }.dropLast(128)
        for key in expired {
            entries.removeValue(forKey: key)
            aliases = aliases.filter { $0.value != key }
            order.removeAll { $0 == key }
        }
    }
}
