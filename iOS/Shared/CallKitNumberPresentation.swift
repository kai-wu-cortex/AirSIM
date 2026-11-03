import CallKit
import Foundation

/// A remote SIM's national number is not necessarily in the iPhone/Watch's region.
/// Never infer a calling code from the local device's locale or account region.
enum CallKitNumberPresentation {
    static func handle(number: String?, fallback: String = "未知号码") -> CXHandle {
        let value = number.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? fallback
        return CXHandle(type: hasExplicitInternationalNumber(value) ? .phoneNumber : .generic,
                        value: value)
    }

    static func update(number: String?, callerName: String?, fallback: String = "未知号码") -> CXCallUpdate {
        let update = CXCallUpdate()
        let handle = handle(number: number, fallback: fallback)
        update.remoteHandle = handle
        if let callerName, !callerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           callerName != number {
            update.localizedCallerName = callerName
        } else if handle.type == .generic {
            // Keep unqualified numbers literal instead of asking the system to
            // format them in its own region. App-side contact matching still works.
            update.localizedCallerName = handle.value
        }
        return update
    }

    private static func hasExplicitInternationalNumber(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return false }
        let body = trimmed.dropFirst()
        let digits = body.filter { ("0"..."9").contains($0) }
        // This is a presentation check, not country-code validation. Preserve the
        // original handle/dial target; neither add a prefix nor convert 00/011.
        return (7...15).contains(digits.count) && digits.first != "0"
            && body.allSatisfy { ("0"..."9").contains($0) || " ()-.".contains($0) }
    }
}
