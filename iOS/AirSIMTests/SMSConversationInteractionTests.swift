import XCTest
import UIKit
@testable import AirSIM

@MainActor
final class SMSConversationInteractionTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func messages(_ count: Int) -> [SMSMessage] {
        (0..<count).map {
            SMSMessage(sender: "ui-fixture", content: "Message \($0): 合成短信 😀\nA selectable second line with https://example.com/test.",
                       code: nil, timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double($0 * 60)),
                       deliveryID: "ui-message-\($0)", direction: $0.isMultiple(of: 3) ? .outgoing : .incoming)
        }
    }

    private func host(_ controller: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return (window, previous)
    }

    func testSelectEnablesReadonlyRangeCopyAndMoreEndsTextSelection() async throws {
        let records = messages(1)
        var selection = SMSMessageSelection()
        var controller: SMSConversationTimelineController!
        func configuration() -> SMSConversationTimelineView {
            SMSConversationTimelineView(messages: records, selection: selection, locale: Locale(identifier: "en_US"),
                onBeginSelection: { id in
                    selection.begin(with: id)
                    controller.update(configuration())
                }, onToggleSelection: { id in
                    selection.toggle(id)
                    controller.update(configuration())
                }, onBeginTextSelection: {})
        }
        controller = SMSConversationTimelineController(presentation: configuration())
        let (window, previous) = try host(controller)
        defer { window.isHidden = true; previous?.makeKeyAndVisible(); controller = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITextView }.first)
        let select = try XCTUnwrap(text.accessibilityCustomActions?.first { $0.name == L10n.t("选择文本") })
        XCTAssertTrue(try XCTUnwrap(select.actionHandler)(select))
        XCTAssertTrue(text.isFirstResponder)
        XCTAssertFalse(text.isEditable)
        XCTAssertEqual(text.selectedRange.length, (records[0].content as NSString).length)

        let previousPasteboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousPasteboard }
        let range = (records[0].content as NSString).range(of: "合成短信 😀")
        text.selectedRange = range
        text.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "合成短信 😀")

        let composer = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        window.addSubview(composer)
        XCTAssertTrue(composer.becomeFirstResponder())
        let collection = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UICollectionView }.first)
        let point = text.convert(CGPoint(x: 4, y: 4), to: collection)
        XCTAssertNotNil(controller.collectionView(collection,
            contextMenuConfigurationForItemAt: IndexPath(item: 0, section: 0), point: point),
            "Focusing the composer must leave text selection and restore the message menu")
        XCTAssertTrue(try XCTUnwrap(select.actionHandler)(select))
        composer.removeFromSuperview()

        let more = try XCTUnwrap(text.accessibilityCustomActions?.first { $0.name == L10n.t("更多…") })
        XCTAssertTrue(try XCTUnwrap(more.actionHandler)(more))
        XCTAssertEqual(selection.selectedIDs, [records[0].id])
        XCTAssertFalse(text.isFirstResponder)
        XCTAssertFalse(text.isUserInteractionEnabled, "Links and text selection must not consume multiselection taps")
        let selectedCell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(selectedCell.accessibilityActivate())
        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.cancel()
        controller.update(configuration())
        XCTAssertTrue(text.isUserInteractionEnabled)
        XCTAssertFalse(text.isFirstResponder)
    }

    func testSelectionAndArrivalsPreserveTheReadingAnchor() async throws {
        var records = messages(30)
        var selection = SMSMessageSelection()
        var controller: SMSConversationTimelineController!
        func configuration() -> SMSConversationTimelineView {
            SMSConversationTimelineView(messages: records, selection: selection, locale: Locale(identifier: "en_US"),
                onBeginSelection: { _ in }, onToggleSelection: { _ in }, onBeginTextSelection: {})
        }
        controller = SMSConversationTimelineController(presentation: configuration())
        let (window, previous) = try host(controller)
        defer { window.isHidden = true; previous?.makeKeyAndVisible(); controller = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        let collection = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UICollectionView }.first)
        let anchor = IndexPath(item: 8, section: 0)
        let initialFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: anchor)).frame
        collection.setContentOffset(CGPoint(x: 0, y: initialFrame.minY + 3), animated: false)
        collection.layoutIfNeeded()
        let offset = initialFrame.minY - collection.contentOffset.y

        selection.begin(with: records[8].id)
        controller.update(configuration())
        let selectedFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: anchor)).frame
        XCTAssertEqual(selectedFrame.minY - collection.contentOffset.y, offset, accuracy: 1)
        records.append(messages(31).last!)
        controller.update(configuration())
        let updatedFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: anchor)).frame
        XCTAssertEqual(updatedFrame.minY - collection.contentOffset.y, offset, accuracy: 1,
                       "Arrivals during multiselection must not pull the conversation to the bottom")
        XCTAssertEqual(selection.selectedIDs, [records[8].id])
    }
}
