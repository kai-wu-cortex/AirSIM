import XCTest

final class SMSNavigationUITests: XCTestCase {
    @MainActor private func openPreferences(in app: XCUIApplication) {
        let row = app.buttons["settings.link.preferences"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if row.exists && row.isHittable {
                row.tap()
                return
            }
            let scroller = form.exists ? form : app
            scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.72))
                .press(forDuration: 0.1, thenDragTo: scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)))
        }
        XCTFail("Settings preferences must remain reachable")
    }

    @MainActor func testGroupedRecentsDetailsAndSettingsReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["最近"].waitForExistence(timeout: 10))
        app.buttons["最近"].tap()
        let group = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        XCTAssertTrue(app.navigationBars["通话详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未接来电"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "173-recents-timeline"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["设置"].tap()
        openPreferences(in: app)
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.waitForExistence(timeout: 5))
        let settingsShot = XCTAttachment(screenshot: app.screenshot()); settingsShot.name = "173-theme-settings"; settingsShot.lifetime = .keepAlways; add(settingsShot)
    }

    @MainActor func testVerificationCodeHighlightWithoutBackendCode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CODE_SMS"] = "1"
        app.launch()
        defer { app.terminate() }
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let codeBody = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(codeBody.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "177-verification-code-highlight"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor func testCodeLongPressMenuAndMissingRegion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CODE_SMS"] = "1"
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        let body = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["复制验证码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["选择文本"].exists)
        XCTAssertTrue(app.buttons["更多…"].exists)
        app.buttons["复制验证码"].firstMatch.tap()
        app.terminate()
        app.launchEnvironment["AIRSIM_UI_CALL"] = "incoming"
        app.launchEnvironment["AIRSIM_UI_REGION_NUMBER"] = "17800159951"
        app.launch()
        XCTAssertTrue(app.staticTexts["北京市"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testAllAndMissedRecentFilter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launchEnvironment["AIRSIM_UI_RECENTS_LONG_REGION"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["最近"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "179-recents-matching-sms-style"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.segmentedControls.buttons["未接来电"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 次通话")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch.exists)
        app.segmentedControls.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testCompactMenusAndUnclutteredThread() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-airsim.appearance", "light"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CODE_SMS"] = "1"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let more = app.buttons["sms-list-actions"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        XCTAssertTrue(app.buttons["刷新短信"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["清空全部短信"].exists)
        let menuShot = XCTAttachment(screenshot: app.screenshot()); menuShot.name = "180-compact-sms-actions"; menuShot.lifetime = .keepAlways; add(menuShot)
        app.buttons["全部已读"].tap()
        more.tap()
        XCTAssertFalse(app.buttons["全部已读"].isEnabled)
        app.buttons["选择会话"].tap()
        more.tap()
        XCTAssertTrue(app.buttons["完成选择"].waitForExistence(timeout: 5))
        app.buttons["完成选择"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        let body = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "123456", "123456")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["验证码 (code)"].exists)
        XCTAssertFalse(app.buttons["复制短信"].exists)
        XCTAssertFalse(app.buttons["复制验证码"].exists)
        let threadShot = XCTAttachment(screenshot: app.screenshot()); threadShot.name = "180-clean-sms-thread"; threadShot.lifetime = .keepAlways; add(threadShot)
        body.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["复制验证码"].waitForExistence(timeout: 5))
        app.buttons["复制验证码"].tap()
        app.terminate(); app.launch()
        app.buttons["最近"].tap()
        let markRead = app.buttons["recents.markAllSeen"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))
        XCTAssertEqual(markRead.label, "将全部未接来电标为已读")
        let recentShot = XCTAttachment(screenshot: app.screenshot()); recentShot.name = "180-explicit-mark-read"; recentShot.lifetime = .keepAlways; add(recentShot)
        markRead.tap()
        XCTAssertFalse(markRead.isEnabled)
        app.segmentedControls.buttons["未接来电"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 次通话")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testSMSAndRecentNumberSearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_SEARCH"] = "1"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Navigation Alice")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Alice")).firstMatch.waitForExistence(timeout: 5))
        search.buttons.firstMatch.tap(); search.typeText("pickup-token")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "pickup-token")).firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "177-sms-content-search"; shot.lifetime = .keepAlways; add(shot)
        search.buttons.firstMatch.tap(); search.typeText("202555")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Alice")).firstMatch.waitForExistence(timeout: 5))
        search.typeText("\n")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        app.buttons["最近"].tap()
        let recentSearch = app.searchFields.firstMatch
        XCTAssertTrue(recentSearch.waitForExistence(timeout: 5))
        recentSearch.tap(); recentSearch.typeText("8000")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch.waitForExistence(timeout: 5))
        recentSearch.buttons.firstMatch.tap(); recentSearch.typeText("99999")
        XCTAssertTrue(app.staticTexts["未找到匹配号码"].waitForExistence(timeout: 5))
    }

    @MainActor func testOfflineRegionCStyleInCallAndHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "incoming"
        app.launchEnvironment["AIRSIM_UI_REGION"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["SIM 2 · 北京市"].waitForExistence(timeout: 10))
        let incoming = XCTAttachment(screenshot: app.screenshot()); incoming.name = "177-region-C-incoming"; incoming.lifetime = .keepAlways; add(incoming)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "AIRSIM_UI_CALL")
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["最近"].tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["北京市"].exists); row.tap()
        XCTAssertTrue(app.staticTexts["北京市"].waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: app.screenshot()); details.name = "177-region-C-history"; details.lifetime = .keepAlways; add(details)
    }

    @MainActor func testThemeSwitchAndGroupedDelete() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap()
        openPreferences(in: app)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.tap()
        app.buttons["墨绿"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "跟随系统")).firstMatch.tap()
        app.buttons["深色"].tap()
        XCTAssertFalse(app.staticTexts["蓝牙诊断（已脱敏）"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "173-forest-dark"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["最近"].tap()
        let group = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.swipeLeft()
        app.buttons["删除全部记录"].tap()
        app.buttons["删除 2 条记录"].tap()
        XCTAssertFalse(group.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSMSLineMenuSwitchesInThreadAndCompose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_SMS_SIM"] = "1"
        app.launch()
        defer { app.terminate() }
        let compose = app.buttons["sms-compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let selector = app.buttons["sms.simSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        XCTAssertTrue(selector.label.contains("SIM 2"))
        selector.tap()
        let firstSIM = app.buttons["SIM 1"]
        XCTAssertTrue(firstSIM.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(firstSIM.frame.width, 240)
        XCTAssertLessThanOrEqual(firstSIM.frame.height, 60)
        let compactShot = XCTAttachment(screenshot: app.screenshot())
        compactShot.name = "176-compact-sim-popover"; compactShot.lifetime = .keepAlways; add(compactShot)
        firstSIM.tap()
        XCTAssertTrue(selector.label.contains("SIM 1"))
        app.buttons["取消"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch.tap()
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        app.buttons["SIM 1"].tap()
        XCTAssertTrue(selector.label.contains("SIM 1"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "sms-line-selector-thread"
        shot.lifetime = .keepAlways
        add(shot)
    }

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
            if compose.exists && compose.isHittable {
                // Expanded Duo/iPad keeps the conversation beside the list and
                // preserves tabs. Verify distinct columns, not just visible chrome.
                XCTAssertTrue(row.isHittable)
                let reply = app.descendants(matching: .any).matching(identifier: "sms.reply").firstMatch
                XCTAssertTrue(reply.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(row.frame.maxX, reply.frame.minX,
                    "expanded conversation must occupy a separate detail column")
                XCTAssertTrue(app.buttons["短信"].isHittable)
            } else {
                XCTAssertFalse(app.buttons["短信"].isHittable, "compact conversation must cover the root tabs")
                let systemBack = app.buttons["BackButton"]
                if systemBack.exists {
                    systemBack.tap()
                } else {
                    navigation.buttons.firstMatch.tap()
                }
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

final class SettingsJourneyUITests: XCTestCase {
    @MainActor private func launchSettings() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-home"; shot.lifetime = .keepAlways; add(shot)
        return app
    }

    @MainActor private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["settings.link.\(id)"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<18 {
            if row.exists && row.isHittable {
                // A very large row can be partially behind native glass bars.
                // Scroll its center into the viewport before resolving the hit point.
                let frame = form.exists ? form.frame : app.frame
                var viewport = frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
                // Duo places system bars on a vertical edge. Only subtract the
                // edge a bar actually occupies; never treat a sidebar as a header.
                for bar in [app.navigationBars.firstMatch, app.tabBars.firstMatch] where bar.exists {
                    let bounds = bar.frame
                    if bounds.width > bounds.height, bounds.height < frame.height * 0.4 {
                        if bounds.midY < frame.midY {
                            let top = max(viewport.minY, bounds.maxY + 8)
                            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
                        } else {
                            viewport.size.height = max(0, min(viewport.maxY, bounds.minY - 8) - viewport.minY)
                        }
                    } else if bounds.width < frame.width * 0.3 {
                        if bounds.midX < frame.midX {
                            let left = max(viewport.minX, bounds.maxX + 8)
                            viewport = CGRect(x: left, y: viewport.minY, width: max(0, viewport.maxX - left), height: viewport.height)
                        } else {
                            viewport.size.width = max(0, min(viewport.maxX, bounds.minX - 8) - viewport.minX)
                        }
                    }
                }
                let visible = row.frame.intersection(viewport)
                if !visible.isNull, viewport.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) {
                    // Let XCTest resolve the element's hit point after layout.
                    // Absolute app coordinates can become stale when Duo swaps
                    // displays or changes orientation as the keyboard appears.
                    row.tap()
                    return
                }
            }
            let scroller = form.exists ? form : app
            scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.72))
                .press(forDuration: 0.1, thenDragTo: scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)))
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "unreachable-\(id)"; shot.lifetime = .keepAlways; add(shot)
        XCTFail("Navigation entry is not reachable: \(id)")
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
        else { app.navigationBars.firstMatch.buttons.firstMatch.tap() }
    }

    @MainActor func testCategoriesAndManualPairingPreserveNavigation() {
        let app = launchSettings(); defer { app.terminate() }
        open("connections", in: app)
        XCTAssertTrue(app.navigationBars["连接与设备"].waitForExistence(timeout: 3))
        open("add", in: app)
        open("pairManual", in: app)
        XCTAssertTrue(app.textFields["manualPairingHost"].waitForExistence(timeout: 3))
        let connect = app.buttons["连接并加密配对"]
        // A short Duo window lazily creates the bottom Form rows after scrolling.
        for _ in 0..<6 where !connect.exists {
            let form = app.collectionViews.firstMatch
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)))
        }
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)
        back(app)
        XCTAssertTrue(app.navigationBars["添加设备"].waitForExistence(timeout: 3))
        back(app); back(app)
        open("widgets", in: app)
        open("widgetGuide", in: app)
        XCTAssertTrue(app.staticTexts["添加小组件"].waitForExistence(timeout: 3))
        back(app); back(app)
        open("preferences", in: app)
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-preferences"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testFeedbackDraftSurvivesRangePreviewAndReturn() {
        let app = launchSettings(); defer { app.terminate() }
        open("help", in: app); open("feedback", in: app)
        let text = app.textFields["settings.feedbackDescription"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.tap()
        if let previous = text.value as? String, previous != text.placeholderValue {
            text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        text.typeText("settings draft retained")
        XCTAssertEqual(text.value as? String, "settings draft retained")
        let done = app.toolbars.buttons["完成"]
        if done.exists { done.tap() }
        open("feedbackPreview", in: app)
        XCTAssertTrue(app.navigationBars["上传内容范围"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings draft retained"].waitForExistence(timeout: 3))
        back(app)
        XCTAssertEqual(app.textFields["settings.feedbackDescription"].value as? String, "settings draft retained")
        // This journey deliberately never taps Upload.
    }

    @MainActor func testBluetoothModeAllowsManualCloudSelfTestWithoutRunningIt() {
        let app = launchSettings(); defer { app.terminate() }
        open("help", in: app); open("diagnostics", in: app); open("cloudCheck", in: app)
        let run = app.buttons["运行云端模式自检"]
        XCTAssertTrue(run.waitForExistence(timeout: 3))
        XCTAssertTrue(run.isEnabled)
        // No live Relay request, call, SMS or feedback upload in this test.
    }
}


extension SettingsJourneyUITests {
    @MainActor func testLargeTypeCategoryNavigationAndScreenshots() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        for (id, title) in [("connections", "连接与设备"), ("calls", "来电与短信"),
                            ("widgets", "灵动岛与小组件"), ("preferences", "外观与偏好"),
                            ("help", "帮助与诊断"), ("about", "关于 AirSIM")] {
            open(id, in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "settings-large-\(id)"; shot.lifetime = .keepAlways; add(shot)
            back(app)
        }
    }
}


extension SettingsJourneyUITests {
    @MainActor func testLandscapeSettingsCategories() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        testLargeTypeCategoryNavigationAndScreenshots()
    }
}
