import Foundation

enum CallLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case ringing
    case connecting
    case active
    case ending
    case ended
    case failed

    var isTerminal: Bool { self == .ended || self == .failed }
    var representsCall: Bool { self != .idle && !isTerminal }

    var callRecordState: String {
        switch self {
        case .idle: return "idle"
        case .ringing: return "incoming"
        case .connecting: return "dialing"
        case .active: return "active"
        case .ending: return "ending"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }
}

enum CallLifecycleSource: String, Codable, Equatable, Sendable {
    case app
    case callKit = "callkit"
    case agent
    case relay
}

struct CallLifecycleEvent: Equatable, Sendable {
    let callID: String
    let callUUID: UUID
    let generation: UInt64
    let state: CallLifecycleState
    let source: CallLifecycleSource
    let timestamp: Date
    let traceID: String?
    let failure: String?
}

struct CallLifecycleSnapshot: Equatable, Sendable {
    let callID: String?
    let callUUID: UUID?
    let generation: UInt64
    let state: CallLifecycleState
    let source: CallLifecycleSource?
    let timestamp: Date?
    let traceID: String?
    let failure: String?

    static let idle = CallLifecycleSnapshot(
        callID: nil,
        callUUID: nil,
        generation: 0,
        state: .idle,
        source: nil,
        timestamp: nil,
        traceID: nil,
        failure: nil
    )
}

/// 单通话状态的唯一归并器。所有来源只能提交事件，不能直接改写最终状态。
struct CallLifecycleStore: Sendable {
    private(set) var snapshot: CallLifecycleSnapshot = .idle

    @discardableResult
    mutating func apply(_ event: CallLifecycleEvent) -> Bool {
        guard !event.callID.isEmpty, event.generation > 0 else { return false }
        let sameIdentity = snapshot.callID == event.callID && snapshot.callUUID == event.callUUID
        if snapshot.generation > 0, !sameIdentity {
            // 旧协议会把每通电话的 generation 都设为 1；上一通进入 ending 或
            // 明确终止后，才允许不同身份的新 ringing/connecting 建立生命周期。
            guard snapshot.state.isTerminal || snapshot.state == .ending,
                  event.state == .ringing || event.state == .connecting else { return false }
        } else if event.generation < snapshot.generation {
            return false
        } else if event.generation == snapshot.generation, snapshot.generation > 0 {
            if let timestamp = snapshot.timestamp, event.timestamp < timestamp { return false }
            guard Self.allows(from: snapshot.state, to: event.state) else { return false }
        } else if event.state == .idle {
            return false
        }

        snapshot = CallLifecycleSnapshot(
            callID: event.callID,
            callUUID: event.callUUID,
            generation: event.generation,
            state: event.state,
            source: event.source,
            timestamp: event.timestamp,
            traceID: event.traceID,
            failure: event.state == .failed ? event.failure : nil
        )
        return true
    }

    private static func allows(from current: CallLifecycleState, to next: CallLifecycleState) -> Bool {
        if current == next { return true }
        switch current {
        case .idle:
            return [.ringing, .connecting, .active, .failed].contains(next)
        case .ringing:
            return [.connecting, .active, .ending, .ended, .failed].contains(next)
        case .connecting:
            return [.active, .ending, .ended, .failed].contains(next)
        case .active:
            return [.ending, .ended, .failed].contains(next)
        case .ending:
            return [.ended, .failed].contains(next)
        case .ended, .failed:
            return false
        }
    }
}
