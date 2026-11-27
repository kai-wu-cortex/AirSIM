import Foundation

struct SMSMessageSelection: Equatable {
    private(set) var isSelecting = false
    private(set) var selectedIDs: Set<String> = []

    init() {}

    mutating func begin(with id: String) {
        isSelecting = true
        selectedIDs = [id]
    }

    mutating func toggle(_ id: String) {
        guard isSelecting else { return }
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
    }

    mutating func cancel() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    mutating func reconcile(with messages: [SMSMessage]) {
        selectedIDs.formIntersection(messages.map(\.id))
    }

    func selectedMessages(in messages: [SMSMessage]) -> [SMSMessage] {
        SMSConversationPresentation.chronological(messages.filter { selectedIDs.contains($0.id) })
    }
}

struct SMSTimelineItem: Equatable, Identifiable {
    let message: SMSMessage
    let showsTimestamp: Bool
    let showsTail: Bool

    var id: String { message.id }
}

enum SMSConversationPresentation {
    private static let formatters = SMSConversationTimestampFormatters()

    static func timeline(
        _ messages: [SMSMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SMSTimelineItem] {
        let ordered = chronological(messages)
        return ordered.indices.map { index in
            let message = ordered[index]
            let showsTimestamp = index == ordered.startIndex
                || startsTimestampGroup(message, after: ordered[index - 1], calendar: calendar)
            let nextIndex = index + 1
            let showsTail = nextIndex == ordered.endIndex
                || ordered[nextIndex].isOutgoing != message.isOutgoing
                || startsTimestampGroup(ordered[nextIndex], after: message, calendar: calendar)
            return SMSTimelineItem(message: message, showsTimestamp: showsTimestamp, showsTail: showsTail)
        }
    }

    static func timestamp(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatters.string(from: date, relativeTo: now, calendar: calendar, locale: locale)
    }

    fileprivate static func chronological(_ messages: [SMSMessage]) -> [SMSMessage] {
        messages.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    private static func startsTimestampGroup(
        _ message: SMSMessage,
        after previous: SMSMessage,
        calendar: Calendar
    ) -> Bool {
        !calendar.isDate(message.timestamp, inSameDayAs: previous.timestamp)
            || message.timestamp.timeIntervalSince(previous.timestamp) >= 300
    }
}

/// A single bounded cache keeps formatter allocation out of row rendering. The lock protects
/// both configuration changes and formatting when callers use different calendars or locales.
private final class SMSConversationTimestampFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: Configuration?
    private let time = DateFormatter()
    private let weekday = DateFormatter()
    private let monthDay = DateFormatter()
    private let fullDate = DateFormatter()
    private let relativeDay = RelativeDateTimeFormatter()

    private struct Configuration: Equatable {
        let calendar: Calendar
        let locale: Locale
    }

    func string(from date: Date, relativeTo now: Date, calendar: Calendar, locale: Locale) -> String {
        lock.lock()
        defer { lock.unlock() }
        let requested = Configuration(calendar: calendar, locale: locale)
        if configuration != requested {
            for formatter in [time, weekday, monthDay, fullDate] {
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
            }
            time.dateStyle = .none
            time.timeStyle = .short
            weekday.setLocalizedDateFormatFromTemplate("EEEE")
            monthDay.setLocalizedDateFormatFromTemplate("MMMd")
            fullDate.setLocalizedDateFormatFromTemplate("yMMMd")
            relativeDay.locale = locale
            relativeDay.calendar = calendar
            relativeDay.dateTimeStyle = .named
            relativeDay.unitsStyle = .full
            relativeDay.formattingContext = .beginningOfSentence
            configuration = requested
        }

        let dayDistance = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day
        let dayLabel: String
        switch dayDistance ?? Int.max {
        case 0:
            dayLabel = relativeDay.localizedString(from: DateComponents(day: 0))
        case 1:
            dayLabel = relativeDay.localizedString(from: DateComponents(day: -1))
        case 2...6:
            dayLabel = weekday.string(from: date)
        default:
            let dateYear = calendar.dateComponents([.era, .year], from: date)
            let currentYear = calendar.dateComponents([.era, .year], from: now)
            dayLabel = dateYear == currentYear ? monthDay.string(from: date) : fullDate.string(from: date)
        }
        return "\(dayLabel) \(time.string(from: date))"
    }
}

/// Presentation-only feedback. A timer never turns an uncertain submission into
/// success and never retries it. MU300's cooldown applies to the whole device.
struct SMSSubmissionFeedback: Equatable {
    enum Kind: Equatable { case uncertain, protected, busy, failed }
    let kind: Kind
    let recipient: String
    let message: String
    let retryAfter: Date?

    func remainingSeconds(at date: Date) -> Int {
        guard let retryAfter else { return 0 }
        return max(0, Int(ceil(retryAfter.timeIntervalSince(date))))
    }

    func isVisible(for recipient: String, at date: Date) -> Bool {
        self.recipient == recipient || remainingSeconds(at: date) > 0
    }

    static func make(detail: String, recipient: String, startedAt: Date, now: Date,
                     previous: Self? = nil) -> Self {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let unknown = "短信发送结果待确认。短信可能已经发出，草稿已保留。请先向收件方核实，避免重复发送。"
        if lower == "previous sms outcome unknown; check recipient before retrying after two minutes" {
            // Keep our original deadline if known. An older/different client may
            // have started the protection window; then wait a conservative 120s.
            let deadline = previous?.retryAfter.flatMap { $0 > now ? $0 : nil }
                ?? now.addingTimeInterval(120)
            return Self(kind: .protected, recipient: recipient,
                        message: "短信设备正在保护期内，暂时不能再次发送。上一条短信的结果尚未确认，请先核实收件方；保护期结束后也不会自动重发。",
                        retryAfter: deadline)
        }
        if lower == "sms submission not confirmed; check recipient before retrying; no automatic resend" {
            return Self(kind: .uncertain, recipient: recipient, message: unknown,
                        retryAfter: startedAt.addingTimeInterval(120))
        }
        if lower == "sms submission in progress; do not repeat" {
            return Self(kind: .busy, recipient: recipient,
                        message: "短信仍在设备上处理中，请稍后查看结果，勿重复发送。草稿已保留。", retryAfter: nil)
        }
        if lower == "sms accepted by modem but receipt not saved; do not resend" {
            return Self(kind: .uncertain, recipient: recipient,
                        message: "短信已被基带接受，但成功回执未能保存。请先核实收件方，勿重复发送。", retryAfter: startedAt.addingTimeInterval(120))
        }
        if text.contains("结果尚未确认") || text.contains("发送回执超时") || text.contains("发送等待被中断") {
            // Android does not share MU300's two-minute policy.
            return Self(kind: .uncertain, recipient: recipient, message: unknown, retryAfter: nil)
        }
        let translated: String
        switch lower {
        case "mu300 sms requires a valid number and 1-70 characters":
            translated = "短信未发送。请检查收件号码；此设备每条短信支持 1–70 个字符。"
        case "mu300 sms does not support emoji or control characters":
            translated = "短信未发送。此设备暂不支持表情符号或特殊控制字符，请修改内容。"
        case "finish calls before sending sms; unknown call state blocks submission":
            translated = "短信未发送。请先结束通话，并等待设备确认通话已结束。"
        case "native sms backend unavailable":
            translated = "短信未发送。设备的短信服务暂不可用，请检查设备状态。"
        case "sms submission state needs review", "sms submission state unavailable":
            translated = "短信未发送。设备无法读取发送状态，请检查设备日志后再试。"
        default:
            let hasChinese = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            translated = hasChinese ? "短信发送未完成。\(text)"
                : "短信发送未确认。请检查设备连接，并先核实收件方是否收到，避免重复发送。草稿已保留。"
        }
        return Self(kind: .failed, recipient: recipient, message: translated, retryAfter: nil)
    }
}
