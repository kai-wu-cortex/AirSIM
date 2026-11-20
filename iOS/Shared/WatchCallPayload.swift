import Foundation
import CryptoKit

struct WatchSMSDirectRoute: Codable, Equatable, Sendable {
    let agentID: String
    let host: String
    let port: UInt16
    let secret: Data
    let clockOffset: TimeInterval

    static func scopedSecret(_ pairing: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("AirSIM.watch.sms.v1".utf8),
                                              using: SymmetricKey(data: pairing)))
    }

    var allowsLocalAccess: Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { part in
            part.isEmpty || !part.allSatisfy { $0.isASCII && $0.isNumber } ? nil : UInt8(part)
        }
        guard values.count == 4, parts.count == 4, port >= 1024, secret.count == 32,
              clockOffset.isFinite, abs(clockOffset) < 3_153_600_000 else { return false }
        switch (values[0], values[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): return true
        default: return false
        }
    }
}

struct WatchSMSDevice: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}
struct WatchSMSRow: Codable, Equatable, Identifiable {
    let id: String
    let agentID: String
    let sender: String
    let preview: String
    let timestamp: Date
    let sim: String?
    let outgoing: Bool
    var unread: Bool
    var deliveryKey: String? = nil
}
struct WatchSMSPage: Codable, Equatable {
    let devices: [WatchSMSDevice]
    let selectedAgentID: String?
    var rows: [WatchSMSRow]
    let total: Int
    let generatedAt: Date
}
struct WatchSMSDetail: Codable, Equatable {
    let row: WatchSMSRow
    let body: String
    let truncated: Bool
}
enum WatchSMSPolicy {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func merged(direct: [WatchSMSRow], companion: [WatchSMSRow], agentID: String) -> [WatchSMSRow] {
        var result = direct.filter { $0.agentID == agentID }
        let directCount = result.count
        var matched = Set<Int>()
        for row in companion where row.agentID == agentID {
            let duplicate = result.indices.first { index in
                let candidate = result[index]
                if candidate.id == row.id { return true }
                if let left = candidate.deliveryKey, let right = row.deliveryKey { return left == right }
                return index < directCount && candidate.id.hasPrefix("lan:") && !matched.contains(index)
                    && candidate.timestamp == row.timestamp && candidate.preview == row.preview
                    && candidate.outgoing == row.outgoing && candidate.sim == row.sim
                    && WatchSMSConversationPolicy.peer(candidate.sender) == WatchSMSConversationPolicy.peer(row.sender)
            }
            if let duplicate {
                matched.insert(duplicate)
                result[duplicate].unread = result[duplicate].unread && row.unread
            } else {
                result.append(row)
            }
        }
        return result.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }

    static func readKey(messageID: String, deliveryKey: String?) -> String {
        if let deliveryKey { return "delivery:" + deliveryKey }
        return "message:" + messageID
    }

    static let payloadBudget = 28_000
    static func selected(requested: String?, current: String?, paired: [String]) -> String? {
        if let requested { return paired.contains(requested) ? requested : nil }
        if let current, paired.contains(current) { return current }
        return paired.count == 1 ? paired.first : nil
    }
    static func permits(sourceAgentID: String?, selectedAgentID: String?, pairedIDs: [String]) -> Bool {
        guard let sourceAgentID, let selectedAgentID else { return false }
        return sourceAgentID == selectedAgentID && pairedIDs.contains(sourceAgentID)
    }
    static func prefix(_ text: String, utf8Limit: Int) -> String {
        guard utf8Limit > 0 else { return "" }
        var count = 0
        return String(text.prefix { character in
            let bytes = String(character).utf8.count
            guard count + bytes <= utf8Limit else { return false }
            count += bytes
            return true
        })
    }
    static func boundedDetail(row: WatchSMSRow, body: String) throws -> WatchSMSDetail {
        var limit = 20_000
        while true {
            let text = prefix(body, utf8Limit: limit)
            let detail = WatchSMSDetail(row: row, body: text, truncated: text != body)
            if try JSONEncoder().encode(detail).count <= payloadBudget { return detail }
            guard limit > 0 else { throw NSError(domain: "WatchSMSPayload", code: 1) }
            limit /= 2
        }
    }
    static func matches(_ row: WatchSMSRow, agentID: String, id: String) -> Bool {
        row.agentID == agentID && row.id == id
    }
}

struct WatchSMSConversation: Identifiable, Equatable {
    let id: String
    let agentID: String
    let peer: String
    let rows: [WatchSMSRow]
    var latest: WatchSMSRow { rows[rows.count - 1] }
    var unreadCount: Int { rows.filter { !$0.outgoing && $0.unread }.count }
}

enum WatchSMSConversationPolicy {
    static func peer(_ sender: String) -> String {
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\t")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "text:" + raw }
        var digits = raw.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return "text:" + raw }
        let international = raw.hasPrefix("+") || digits.hasPrefix("00")
        if digits.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        if international {
            if digits.hasPrefix("86"), digits.count > 2 { return "number:" + digits.dropFirst(2) }
            return "international:" + digits
        }
        if digits.count == 13, digits.hasPrefix("861") { digits = String(digits.dropFirst(2)) }
        return "number:" + digits
    }
    static func groups(_ rows: [WatchSMSRow]) -> [WatchSMSConversation] {
        let grouped = Dictionary(grouping: rows) { row in
            let value = peer(row.sender)
            return Data(row.agentID.utf8).base64EncodedString() + "." + Data((value.isEmpty ? "unknown:" + row.id : value).utf8).base64EncodedString()
        }
        return grouped.map { id, values in
            let sorted = values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            return WatchSMSConversation(id: id, agentID: sorted[0].agentID, peer: peer(sorted[0].sender), rows: sorted)
        }.sorted { $0.latest.timestamp == $1.latest.timestamp ? $0.id < $1.id : $0.latest.timestamp > $1.latest.timestamp }
    }
}


struct WatchSMSReplyOptions: Codable {
    struct Slot: Codable, Identifiable {
        let id: String
        let label: String
        let carrier: String?
    }
    let recipient: String
    let slots: [Slot]
    let selectedID: String?
}

enum WatchSMSReplyOutcome {
    case sent
    case failed(String)
    case uncertain
}

extension WatchSMSConversationPolicy {
    static func replyNumber(_ sender: String) -> String? {
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\t")
        guard raw.unicodeScalars.allSatisfy(allowed.contains),
              !raw.dropFirst().contains("+") else { return nil }
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard (1...30).contains(digits.count) else { return nil }
        return raw.hasPrefix("+") ? "+" + digits : digits
    }
}

struct WatchSMSTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: WatchSMSNoRedirect(), delegateQueue: nil)
    }()

    static func request<Response: Decodable>(_ path: String, route: WatchSMSDirectRoute,
                                                     body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Response {
        guard route.allowsLocalAccess, let url = URL(string: "http://\(route.host):\(route.port)\(path)") else {
            throw URLError(.badURL)
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let auth = SymmetricKey(data: route.secret)
        let encryption = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data("AirSIM.watch.sms.encryption.v1".utf8), using: auth)))
        let payload: Data
        if let body {
            let sealed = try AES.GCM.seal(body, using: encryption, authenticating: Data("request:\(nonce)".utf8))
            guard let combined = sealed.combined else { throw URLError(.cannotParseResponse) }
            payload = combined.base64EncodedData()
        } else { payload = Data() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout ?? (body == nil ? 5 : 75))
        let method = body == nil ? "GET" : "POST"
        request.httpMethod = method
        request.httpBody = body == nil ? nil : payload
        let timestamp = Int64(Date().timeIntervalSince1970 + route.clockOffset)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method)\n\(path)\n\(hash)\n\(timestamp)\n\(nonce)"
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: auth))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for (name, value) in [("Version", "1"), ("Timestamp", String(timestamp)), ("Nonce", nonce), ("Signature", signature)] {
            request.setValue(value, forHTTPHeaderField: "X-AirSIM-VoWLAN-" + name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw WatchDirectError.authentication }
        guard http.statusCode == 200, data.count < 2_000_000,
              let combined = Data(base64Encoded: data) else { throw URLError(.badServerResponse) }
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: encryption,
                                      authenticating: Data("response:\(nonce)".utf8))
        return try JSONDecoder().decode(Response.self, from: opened)
    }

}

struct WatchDirectSend: Decodable {
    let sent: Bool?
    let pending: Bool?
    let unknown: Bool?
    let uncertain: Bool?
    let error: String?

    var outcome: WatchSMSReplyOutcome {
        if sent == true { return .sent }
        if uncertain == true || pending == true || unknown == true { return .uncertain }
        if let error { return .failed(error) }
        return .uncertain
    }
}

struct WatchSMSCapabilities: Decodable {
    let operation_status: Bool?
}

enum WatchDirectError: LocalizedError {
    case authentication, unavailable
    var errorDescription: String? { "安卓直连暂不可用，请检查 Wi‑Fi 和配对" }
}

private final class WatchSMSNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}


/// Exact service numbers only: a matching prefix is not a carrier identity.
enum SMSCarrierBrand: String, CaseIterable, Sendable {
    case mobile = "SMSCarrierMobile", unicom = "SMSCarrierUnicom", telecom = "SMSCarrierTelecom"
    case icbc = "SMSServiceICBC"
    case ccb = "SMSServiceCCB"
    case abc = "SMSServiceABC"
    case boc = "SMSServiceBOC"
    case bocom = "SMSServiceBOCOM"
    case sf = "SMSServiceSF"
    case jd = "SMSServiceJD"
    case zto = "SMSServiceZTO"
    case yto = "SMSServiceYTO"
    case cmb = "SMSServiceCMB", minsheng = "SMSServiceMinsheng"
    static func match(_ sender: String) -> SMSCarrierBrand? {
        let allowed = CharacterSet(charactersIn: "+0123456789 -()")
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.dropFirst().contains("+") else { return nil }
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if value.hasPrefix("+86") { digits = String(digits.dropFirst(2)) }
        else if value.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if value.hasPrefix("+") { return nil }
        switch digits {
        case "10086": return .mobile
        case "10010": return .unicom
        case "10000": return .telecom
        case "95588": return .icbc
        case "95533": return .ccb
        case "95599": return .abc
        case "95566": return .boc
        case "95559": return .bocom
        case "95338": return .sf
        case "950616": return .jd
        case "95311": return .zto
        case "95554": return .yto
        case "1069095599", "10690955998": return .abc
        case "106980095533": return .ccb
        case "95555", "1065795555", "106941995555", "106807695555", "10694395555", "106913595555", "106903695555", "106918195555", "1069170795555", "1069329095555", "1069411095555", "1068338795555", "1068078595555", "1068775395555", "1068486095555", "1068039095555", "106946895555", "1069208795555", "1069220695555", "106934095555", "106934795555", "1069210395555", "1069232695555", "1069101695555", "106904095555", "106903395555", "106929395555", "1068116095555", "106575595555", "1069118895555", "1068015195555", "106910095555", "1068455695555", "106935295555", "1069109695555", "1069057295555", "1069449695555", "1069249395555", "1069352995555", "106930095555", "106920095555", "1069100995555", "1069001995555", "106900795555": return .cmb
        case "95568", "106980095568", "10680195568", "10685095568", "106857695568", "106835195568", "1068071895568", "1069120695568", "106935595568", "1069161795568", "10691895568", "106901195568": return .minsheng
        default: return nil
        }
    }
}
