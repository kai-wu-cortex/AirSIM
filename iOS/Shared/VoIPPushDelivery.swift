import Foundation

/// Every VoIP delivery needs a synchronous CallKit report, even when its business
/// payload is unusable. Completion belongs to that report, not to UI/route work.
enum VoIPPushDelivery {
    @MainActor
    @discardableResult
    static func receive<Call>(
        payload: [AnyHashable: Any],
        parse: ([AnyHashable: Any]) throws -> Call,
        report: (Call, @escaping () -> Void) -> Void,
        reportRejected: (UUID, @escaping (Error?) -> Void) -> Void,
        endRejected: @escaping (UUID) -> Void,
        rejected: (Error) -> Void,
        completion: @escaping () -> Void
    ) -> Call? {
        let delivery = VoIPPushCompletion()
        do {
            let call = try parse(payload)
            report(call) { delivery.run(completion) }
            return call
        } catch {
            // Never reuse an untrusted/expired payload UUID: ending it could
            // terminate a currently active call or one owned by another device.
            let uuid = UUID()
            reportRejected(uuid) { error in
                delivery.run {
                    if error == nil { endRejected(uuid) }
                    completion()
                }
            }
            rejected(error)
            return nil
        }
    }
}

private final class VoIPPushCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func run(_ action: () -> Void) {
        lock.lock()
        let first = !completed
        completed = true
        lock.unlock()
        if first { action() }
    }
}
