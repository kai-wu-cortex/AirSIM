import Foundation

enum SMSConversationSearch {
    static func matches(_ query: String, sender: String, contactName: String?, contents: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if contains(sender, query: query) || contains(contactName ?? "", query: query)
            || contents.contains(where: { contains($0, query: query) }) { return true }
        let phoneCharacters = CharacterSet.decimalDigits.union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "+()-（）－"))
        guard query.unicodeScalars.allSatisfy(phoneCharacters.contains) else { return false }
        let digits = normalizedDigits(query)
        return !digits.isEmpty && normalizedDigits(sender).contains(digits)
    }

    static func contains(_ content: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && content.range(of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current) != nil
    }

    private static func normalizedDigits(_ value: String) -> String {
        value.compactMap(\.wholeNumberValue).map(String.init).joined()
    }
}
