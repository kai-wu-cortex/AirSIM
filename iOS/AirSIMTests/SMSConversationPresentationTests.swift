import XCTest
@testable import AirSIM

final class SMSConversationPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(
        _ year: Int = 2026, _ month: Int = 10, _ day: Int = 28,
        _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
        calendar: Calendar? = nil
    ) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private func message(
        _ id: String, at timestamp: Date,
        direction: SMSDirection? = .incoming, source: String? = nil
    ) -> SMSMessage {
        SMSMessage(sender: "test-sender", content: "same synthetic payload", code: nil,
                   timestamp: timestamp, deliveryID: id, direction: direction, sourceAgentID: source)
    }

    private func formatted(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func shortTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func testEmptyAndSingleMessageTimeline() {
        XCTAssertEqual(SMSConversationPresentation.timeline([]), [])
        let sms = message("single", at: date())
        XCTAssertEqual(SMSConversationPresentation.timeline([sms]), [
            SMSTimelineItem(message: sms, showsTimestamp: true, showsTail: true)
        ])
    }

    func testChronologicalOrderUsesExistingIDToBreakTimestampTies() {
        let a = message("a", at: date())
        let b = message("b", at: date())
        let earlier = message("z", at: date().addingTimeInterval(-1))
        XCTAssertEqual(SMSConversationPresentation.timeline([b, a, earlier]).map(\.id),
                       [earlier.id, a.id, b.id])
    }

    func testTimestampGapThresholdAndTailGroupBoundaries() {
        let start = date()
        let messages = [
            message("a", at: start),
            message("b", at: start.addingTimeInterval(299)),
            message("c", at: start.addingTimeInterval(599)),
            message("d", at: start.addingTimeInterval(900))
        ]
        let items = SMSConversationPresentation.timeline(messages, calendar: calendar())
        XCTAssertEqual(items.map(\.showsTimestamp), [true, false, true, true])
        XCTAssertEqual(items.map(\.showsTail), [false, true, true, true])
    }

    func testDayChangeStartsGroupEvenBelowFiveMinutes() {
        let messages = [
            message("a", at: date(2026, 10, 27, 23, 59)),
            message("b", at: date(2026, 10, 28, 0, 0))
        ]
        let items = SMSConversationPresentation.timeline(messages, calendar: calendar())
        XCTAssertEqual(items.map(\.showsTimestamp), [true, true])
        XCTAssertEqual(items.map(\.showsTail), [true, true])
    }

    func testDirectionChangesCloseRunsAndLegacyDirectionIsIncoming() {
        let start = date()
        let directions: [SMSDirection?] = [nil, .incoming, .outgoing, .outgoing, .incoming]
        let messages = directions.enumerated().map {
            message("\($0.offset)", at: start.addingTimeInterval(Double($0.offset)), direction: $0.element)
        }
        let items = SMSConversationPresentation.timeline(messages, calendar: calendar())
        XCTAssertEqual(items.map(\.showsTimestamp), [true, false, false, false, false])
        XCTAssertEqual(items.map(\.showsTail), [false, true, false, true, true])
    }

    func testTimelineUsesInjectedTimezoneForDayBoundaries() {
        let messages = [
            message("a", at: date(2026, 10, 28, 6, 59)),
            message("b", at: date(2026, 10, 28, 7, 0))
        ]
        XCTAssertEqual(SMSConversationPresentation.timeline(messages, calendar: calendar()).map(\.showsTimestamp),
                       [true, false])
        XCTAssertEqual(SMSConversationPresentation.timeline(messages, calendar: calendar("America/Los_Angeles"))
            .map(\.showsTimestamp), [true, true])
    }

    func testTodayAndYesterdayLabelsUseInjectedNow() {
        let now = date()
        let yesterday = date(2026, 10, 27)
        let todayLabel = SMSConversationPresentation.timestamp(now, relativeTo: now,
                                                              calendar: calendar(), locale: english)
        let yesterdayLabel = SMSConversationPresentation.timestamp(yesterday, relativeTo: now,
                                                                  calendar: calendar(), locale: english)
        XCTAssertEqual(todayLabel, "Today \(shortTime(now, calendar: calendar(), locale: english))")
        XCTAssertEqual(yesterdayLabel, "Yesterday \(shortTime(yesterday, calendar: calendar(), locale: english))")
    }

    func testPrecedingSixDaysUseWeekdayAndSevenDaysUseMonthDay() {
        let now = date()
        let cal = calendar()
        for offset in 2...7 {
            let earlier = cal.date(byAdding: .day, value: -offset, to: now)!
            let template = offset <= 6 ? "EEEE" : "MMMd"
            let expected = "\(formatted(earlier, template: template, calendar: cal, locale: english)) \(shortTime(earlier, calendar: cal, locale: english))"
            XCTAssertEqual(SMSConversationPresentation.timestamp(earlier, relativeTo: now, calendar: cal, locale: english),
                           expected, "day offset \(offset)")
        }
    }

    func testOlderSameYearAndPreviousYearUseLocalizedDatesAndShortTime() {
        let cal = calendar()
        for (earlier, template) in [(date(2026, 3, 2), "MMMd"), (date(2025, 3, 2), "yMMMd")] {
            for locale in [english, Locale(identifier: "zh_CN"), Locale(identifier: "en_GB")] {
                let expected = "\(formatted(earlier, template: template, calendar: cal, locale: locale)) \(shortTime(earlier, calendar: cal, locale: locale))"
                XCTAssertEqual(SMSConversationPresentation.timestamp(earlier, relativeTo: date(), calendar: cal, locale: locale), expected)
            }
        }
    }

    func testRelativeLabelsAreLocalized() {
        let locale = Locale(identifier: "zh_CN")
        let cal = calendar()
        let now = date()
        XCTAssertEqual(SMSConversationPresentation.timestamp(now, relativeTo: now, calendar: cal, locale: locale),
                       "今天 \(shortTime(now, calendar: cal, locale: locale))")
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(SMSConversationPresentation.timestamp(yesterday, relativeTo: now, calendar: cal, locale: locale),
                       "昨天 \(shortTime(yesterday, calendar: cal, locale: locale))")
    }

    func testTimezoneChangesRelativeDayAndFormatterConfiguration() {
        let now = date(2026, 10, 28, 7, 30)
        let earlier = date(2026, 10, 28, 6, 30)
        for (cal, label) in [(calendar(), "today"), (calendar("America/Los_Angeles"), "yesterday"), (calendar(), "today")] {
            let expected = "\(label) \(shortTime(earlier, calendar: cal, locale: english))"
            XCTAssertEqual(SMSConversationPresentation.timestamp(earlier, relativeTo: now, calendar: cal, locale: english).lowercased(),
                           expected.lowercased())
        }
    }

    func testDSTYesterdayIsCalendarDayNotTwentyFourHours() {
        let cal = calendar("America/Los_Angeles")
        for (now, earlier) in [
            (date(2026, 3, 9, 0, 15, calendar: cal), date(2026, 3, 8, 0, 15, calendar: cal)),
            (date(2026, 11, 2, 0, 15, calendar: cal), date(2026, 11, 1, 0, 15, calendar: cal))
        ] {
            XCTAssertNotEqual(now.timeIntervalSince(earlier), 86_400)
            let expected = "yesterday \(shortTime(earlier, calendar: cal, locale: english))"
            XCTAssertEqual(SMSConversationPresentation.timestamp(earlier, relativeTo: now, calendar: cal, locale: english).lowercased(),
                           expected.lowercased())
        }
    }

    func testSelectionRequiresBeginAndZeroSelectionStaysActive() {
        var selection = SMSMessageSelection()
        selection.toggle("ignored")
        XCTAssertEqual(selection, SMSMessageSelection())
        selection.begin(with: "trigger")
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.selectedIDs, ["trigger"])
        selection.toggle("trigger")
        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.toggle("next")
        XCTAssertEqual(selection.selectedIDs, ["next"])
        selection.cancel()
        XCTAssertEqual(selection, SMSMessageSelection())
    }

    func testBeginReplacesPreviousSelection() {
        var selection = SMSMessageSelection()
        selection.begin(with: "old")
        selection.toggle("another")
        selection.begin(with: "new")
        XCTAssertEqual(selection.selectedIDs, ["new"])
    }

    func testReconcileRemovesDisappearedIDsWithoutSelectingArrivalsOrExiting() {
        let kept = message("kept", at: date())
        let arrival = message("arrival", at: date())
        var selection = SMSMessageSelection()
        selection.begin(with: kept.id)
        selection.toggle("removed")
        selection.reconcile(with: [kept, arrival])
        XCTAssertEqual(selection.selectedIDs, [kept.id])
        selection.reconcile(with: [arrival])
        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.cancel()
        selection.reconcile(with: [kept, arrival])
        XCTAssertEqual(selection, SMSMessageSelection())
    }

    func testIdenticalPayloadsFromDifferentSourcesRemainIndependentlySelectable() {
        let first = message("shared", at: date(), source: "first")
        let second = message("shared", at: date(), source: "second")
        XCTAssertNotEqual(first.id, second.id)
        var selection = SMSMessageSelection()
        selection.begin(with: first.id)
        XCTAssertEqual(selection.selectedMessages(in: [second, first]), [first])
        selection.reconcile(with: [second])
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertTrue(selection.selectedMessages(in: [second]).isEmpty)
    }

    func testSelectedMessagesUseExactExistingIDsAndChronologicalSharingOrder() {
        let late = message("late", at: date().addingTimeInterval(60))
        let tieB = message("b", at: date())
        let tieA = message("a", at: date())
        let unselected = message("other", at: date().addingTimeInterval(-60))
        var selection = SMSMessageSelection()
        selection.begin(with: late.id)
        selection.toggle(tieB.id)
        selection.toggle(tieA.id)
        selection.toggle("missing")
        XCTAssertEqual(selection.selectedMessages(in: [late, tieB, unselected, tieA]), [tieA, tieB, late])
    }
}
