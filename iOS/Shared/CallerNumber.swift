import Foundation
import Darwin

/// Display-only projection of a numeric IMS caller. Never use for authentication,
/// SIM identity, or arbitrary dial/SMS input. Ambiguous addresses stay opaque.
enum CallerNumber {
    static func display(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 512 else { return raw }
        var rest = value
        var tel = false
        if let colon = value.firstIndex(of: ":") {
            let scheme = value[..<colon].lowercased()
            guard ["sip", "sips", "tel"].contains(scheme) else { return raw }
            tel = scheme == "tel"
            rest = String(value[value.index(after: colon)...])
        } else if !value.contains("@") { return raw }
        guard !rest.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else { return raw }
        let parts = rest.components(separatedBy: "@")
        guard parts.count == (tel ? 1 : 2) else { return raw }
        var seen = Set<String>()
        func parameters(_ parts: [String]) -> Bool {
            for part in parts {
                let pair = part.lowercased().components(separatedBy: "=")
                guard pair.count == 2, seen.insert(pair[0]).inserted else { return false }
                if pair[0] == "user", pair[1] == "phone" { continue }
                if !tel, pair[0] == "transport", ["udp", "tcp", "tls"].contains(pair[1]) { continue }
                return false
            }
            return true
        }
        let user = parts[0].components(separatedBy: ";")
        guard parameters(Array(user.dropFirst())) else { return raw }
        if !tel {
            let host = parts[1].components(separatedBy: ";")
            guard parameters(Array(host.dropFirst())), validAuthority(host[0]) else { return raw }
        }
        guard let decoded = user[0].removingPercentEncoding,
              decoded.range(of: #"^\+?[0-9().-]+$"#, options: .regularExpression) != nil else { return raw }
        let number = decoded.filter { ("0"..."9").contains($0) || $0 == "+" }
        let count = number.filter { $0 != "+" }.count
        return (1...20).contains(count) ? number : raw
    }

    private static func validAuthority(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 260 else { return false }
        let host: String
        let port: String?
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            let address = String(value[value.index(after: value.startIndex)..<end])
            var parsed = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { return false }
            host = "ipv6"
            let suffix = String(value[value.index(after: end)...])
            guard suffix.isEmpty || suffix.hasPrefix(":") else { return false }
            port = suffix.isEmpty ? nil : String(suffix.dropFirst())
        } else {
            let parts = value.components(separatedBy: ":")
            guard parts.count <= 2 else { return false }
            host = parts[0]
            port = parts.count == 2 ? parts[1] : nil
            guard host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                $0.count <= 63 && $0.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
            }) else { return false }
        }
        if let port {
            guard port.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(port), (1...65535).contains(n) else { return false }
        }
        return !host.isEmpty
    }

    static func matching(_ raw: String) -> String {
        let value = display(raw)
        // Never match digits taken from an IMS domain, an extension or opaque user.
        return value.contains(where: { ":@;%".contains($0) }) ? "" : value
    }
}
