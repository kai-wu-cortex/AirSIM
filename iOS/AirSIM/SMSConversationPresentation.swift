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
