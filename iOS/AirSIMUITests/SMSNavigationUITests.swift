import XCTest

final class SMSNavigationUITests: XCTestCase {
    // Duo exposes native tab items outside XCUIElementTypeTabBar. Query the
    // labelled buttons so the same assertions cover both system presentations.
    @MainActor
    private func dismissMicrophonePrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let description = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        guard description.contains("麦克风") || description.localizedCaseInsensitiveContains("microphone") else { return }
        for label in ["不允许", "Don’t Allow", "Don't Allow"] {
            let deny = alert.buttons[label]
            if deny.exists { deny.tap(); return }
        }
    }

    @MainActor
    func testContactsSearchAndRecentsTitleSurviveTabSwitches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.buttons["联系人"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            app.buttons["最近"].tap()
            XCTAssertTrue(app.navigationBars["最近通话"].waitForExistence(timeout: 5))
            app.buttons["设置"].tap()
            app.buttons["短信"].tap()
            XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testConversationReopensAfterSwitchingTabsAndReturning() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        let compose = app.buttons["sms-compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "real toolbar must expose its compose action")
        for iteration in 0..<3 {
            app.buttons["设置"].tap()
            app.buttons["短信"].tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["sms-list-actions"].exists)
            if iteration == 0 {
                compose.tap()
                let cancel = app.buttons["取消"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 5))
                cancel.tap()
                XCTAssertTrue(compose.waitForExistence(timeout: 5))
            }
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let navigation = app.navigationBars["sms-navigation-fixture"]
            XCTAssertTrue(navigation.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["短信"].isHittable, "conversation must cover the root tabs")
            let systemBack = app.buttons["BackButton"]
            if systemBack.exists {
                systemBack.tap()
            } else {
                navigation.buttons.firstMatch.tap()
            }
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["短信"].isHittable)
        }
    }
    @MainActor
    func testDialPadKeepsNumberAcrossRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 10))
        app.buttons["拨号"].tap()
        for label in ["1", "2 ABC", "3 DEF"] { app.buttons[label].tap() }
        let number = app.staticTexts["dialpad.number"]
        XCTAssertEqual(number.label, "123")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["dialpad.clear"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["dialpad.clear"].isHittable)
            XCTAssertTrue(app.buttons["9 WXYZ"].isHittable)
            XCTAssertEqual(number.label, "123")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "dialpad-\(orientation.rawValue)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.buttons["4 GHI"].tap()
        let appended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1234"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [appended], timeout: 5), .completed)
        app.buttons["dialpad.clear"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "输入号码"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
    }

    @MainActor
    func testAccessibilityTextDialPadActionsRemainReachable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 10))
        app.buttons["拨号"].tap()
        app.buttons["1"].tap()
        let clear = app.buttons["dialpad.clear"]
        for _ in 0..<3 where !clear.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(clear.isHittable)
        XCTAssertTrue(app.buttons["#"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "dialpad-accessibility-text-actions"
        shot.lifetime = .keepAlways
        add(shot)
        clear.tap()
        let number = app.staticTexts["dialpad.number"]
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "输入号码"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
    }

    @MainActor
    func testMessageDraftSurvivesRotationWithKeyboard() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let reply = app.descendants(matching: .any).matching(identifier: "sms.reply").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        reply.typeText("draft 123")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(reply.waitForExistence(timeout: 5))
            XCTAssertEqual(reply.value as? String, "draft 123")
            XCTAssertTrue(reply.isHittable)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "sms-draft-\(orientation.rawValue)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    @MainActor
    func testCallControlsAndKeypadRemainReachableInLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for phase in ["incoming", "active"] {
            app.launchEnvironment["AIRSIM_UI_CALL"] = phase
            app.launch()
            dismissMicrophonePrompt()
            XCUIDevice.shared.orientation = .landscapeLeft
            let action = app.buttons[phase == "incoming" ? "接听" : "挂断"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            if !action.isHittable { app.swipeUp() }
            let callShot = XCTAttachment(screenshot: app.screenshot())
            callShot.name = "call-\(phase)-before-hit-test"
            callShot.lifetime = .keepAlways
            add(callShot)
            if !action.isHittable {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "call-hit-test-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(action.isHittable)
            XCTAssertFalse(app.buttons["短信"].isHittable, "call surface must cover the root tabs")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "call-\(phase)-landscape"
            shot.lifetime = .keepAlways
            add(shot)
            if phase == "active" {
                app.buttons["键盘"].tap()
                XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
                app.swipeUp()
                XCTAssertTrue(app.buttons["发送 DTMF #"].isHittable)
                app.buttons["取消"].tap()
                XCTAssertTrue(action.waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

}
