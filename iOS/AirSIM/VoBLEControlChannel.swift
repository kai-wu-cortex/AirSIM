import Foundation

enum VoBLEControlResolution: Equatable, Sendable {
    case accepted
    case stale
    case missing
}

struct VoBLEControlRequestLedger: Sendable {
    private struct Pending: Sendable {
        let generation: UInt64
        let deadline: Date
    }
    private var pending: [String: Pending] = [:]

    mutating func begin(requestID: String, generation: UInt64, deadline: Date) {
        guard !requestID.isEmpty else { return }
        pending[requestID] = Pending(generation: generation, deadline: deadline)
    }

    mutating func resolve(requestID: String, generation: UInt64) -> VoBLEControlResolution {
        guard let value = pending[requestID] else { return .missing }
        guard value.generation == generation else { return .stale }
        pending.removeValue(forKey: requestID)
        return .accepted
    }

    mutating func expire(now: Date) -> [String] {
        let expired = pending.compactMap { key, value in
            value.deadline < now ? key : nil
        }.sorted()
        expired.forEach { pending.removeValue(forKey: $0) }
        return expired
    }

    mutating func removeAll() { pending.removeAll() }
}
