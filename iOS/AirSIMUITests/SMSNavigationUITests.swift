import XCTest

final class SMSNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testDeviceStatusMovesToSettingsAndOfflinePairingRemainsVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_DEVICE"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 10))
        app.buttons["拨号"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dialpad.number"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["OnePlus PLR110"].exists)
        app.buttons["1"].tap()
        app.buttons["2 ABC"].tap()
        app.buttons["3 DEF"].tap()
        XCTAssertTrue(app.buttons["dialpad.addContact"].exists)
        let dial = XCTAttachment(screenshot: app.screenshot())
        dial.name = "252-clean-dial-pad"; dial.lifetime = .keepAlways; add(dial)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["OnePlus PLR110"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["VoWLAN 离线"].exists)
        let firstNumber = app.descendants(matching: .any)["settings.simNumber.ui-sim-1"]
        let secondNumber = app.descendants(matching: .any)["settings.simNumber.ui-sim-2"]
        let numberShot = XCTAttachment(screenshot: app.screenshot())
        numberShot.name = "253-settings-sim-rows"; numberShot.lifetime = .keepAlways; add(numberShot)
        XCTAssertTrue(firstNumber.exists, app.debugDescription)
        XCTAssertTrue(secondNumber.exists)
        XCTAssertFalse(app.staticTexts["+8613800138000"].exists, "Cached SIM handles must not persist phone numbers")
        XCTAssertTrue(app.staticTexts["上次读取的 SIM 信息"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "252-device-status-settings"; settings.lifetime = .keepAlways; add(settings)
    }

    @MainActor func testDiagnosticsHaveSingleSettingsEntryAndRetainAllChecks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let connection = app.buttons["连接与设备"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.tap()
        XCTAssertTrue(app.switches["cloudSignaling"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["连接模式"].exists)
        XCTAssertFalse(app.buttons["连接与推送诊断"].exists)
        XCTAssertFalse(app.buttons["diagnostics.entry"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let help = app.buttons["帮助与诊断"]
        if !help.isHittable { app.swipeUp() }
        XCTAssertTrue(help.waitForExistence(timeout: 5)); help.tap()
        let diagnostics = app.buttons["diagnostics.entry"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "diagnostics.entry").count, 1)
        XCTAssertFalse(app.buttons["连接与推送诊断"].exists)
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["诊断与修复"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["一键检查"].exists)
        XCTAssertTrue(app.buttons["修复连接与短信同步"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "280-unified-diagnostics"; screenshot.lifetime = .keepAlways; add(screenshot)
        let fullCheck = app.buttons["运行完整自检"]
        for _ in 0..<6 { if fullCheck.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(fullCheck.exists)
        let logs = app.buttons["链路事件与日志导出"]
        for _ in 0..<8 { if logs.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(logs.exists)
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
        let appearance = app.buttons["外观与偏好"]
        for _ in 0..<3 where !appearance.isHittable { app.swipeUp() }
        appearance.tap()
        XCTAssertTrue(app.navigationBars["外观与偏好"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主题")).firstMatch.waitForExistence(timeout: 5))
        let settingsShot = XCTAttachment(screenshot: app.screenshot()); settingsShot.name = "173-theme-settings"; settingsShot.lifetime = .keepAlways; add(settingsShot)
    }

    @MainActor func testMissedCallStaysUnviewedUntilDetailAndShowsAndroidDurations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_RECENTS"] = "1"
        app.launchEnvironment["AIRSIM_UI_VERIFIED_DURATIONS"] = "1"
        app.launch()
        defer { app.terminate() }

        app.buttons["最近"].tap()
        let unviewed = app.staticTexts["未查看"]
        XCTAssertTrue(unviewed.waitForExistence(timeout: 5))
        let group = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 次通话")).firstMatch
        group.tap()
        let detail = app.navigationBars["通话详情"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["响铃 12 秒"].exists)
        XCTAssertTrue(app.staticTexts["最近一通"].exists)
        let history = app.staticTexts["全部记录 · 2 次通话"]
        if !history.isHittable { app.swipeUp() }
        history.tap()
        XCTAssertTrue(app.staticTexts["通话 1 分 3 秒"].exists)
        detail.buttons.firstMatch.tap()
        app.segmentedControls.buttons["未接来电"].tap()
        let missed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 次通话")).firstMatch
        XCTAssertTrue(missed.waitForExistence(timeout: 5))
        XCTAssertFalse(unviewed.exists)
    }

    @available(iOS 16.4, *)
    @MainActor func testExternalDialURLPrefillsWithoutStartingCall() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.open(try XCTUnwrap(URL(string: "tel:+86%20138-0013-8000")))
        defer { app.terminate() }
        let number = app.staticTexts["dialpad.number"]
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "+8613800138000")
        XCTAssertTrue(app.buttons["dialpad.delete"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @available(iOS 16.4, *)
    @MainActor func testExternalMessageURLPrefillsRecipientOnColdLaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.open(try XCTUnwrap(URL(string: "im:+86%20138-0013-8000")))
        defer { app.terminate() }
        let recipient = app.textFields["输入号码或姓名"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 10))
        XCTAssertEqual(recipient.value as? String, "+8613800138000")
        XCTAssertTrue(app.buttons["发送"].exists)
    }

    @MainActor func testDialPadShowsEditingActionsOnlyWithDigits() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-airsim.appearance", "dark"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_DEVICE"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 10))
        app.buttons["拨号"].tap()
        XCTAssertFalse(app.buttons["dialpad.delete"].exists)
        XCTAssertFalse(app.buttons["dialpad.addContact"].exists)
        XCTAssertFalse(app.buttons["dial-pad-sim-slot"].exists)
        let keyFrame = app.buttons["1"].frame
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "255-dial-empty"; empty.lifetime = .keepAlways; add(empty)
        app.buttons["1"].tap()
        XCTAssertTrue(app.buttons["dial-pad-sim-slot"].isHittable)
        app.buttons["dial-pad-sim-slot"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SIM 2")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SIM 2")).firstMatch.tap()
        XCTAssertTrue(app.buttons["dialpad.delete"].isHittable)
        XCTAssertTrue(app.buttons["dialpad.addContact"].isHittable)
        XCTAssertEqual(app.buttons["1"].frame, keyFrame)
        let entered = XCTAttachment(screenshot: app.screenshot())
        entered.name = "255-dial-entered"; entered.lifetime = .keepAlways; add(entered)
        app.buttons["dialpad.delete"].tap()
        XCTAssertFalse(app.buttons["dialpad.delete"].exists)
        XCTAssertFalse(app.buttons["dialpad.addContact"].exists)
        XCTAssertFalse(app.buttons["dial-pad-sim-slot"].exists)
        XCTAssertEqual(app.buttons["1"].frame, keyFrame)
    }

    @MainActor func testCallSurfaceRepeatedlyEntersAndExitsWithoutLeavingControlsBlocked() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-airsim.appearance", "light"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_CALL_TRANSITION"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 10))
        app.buttons["拨号"].tap()
        let toggle = app.buttons["ui.callTransition"]
        for _ in 0..<3 {
            toggle.tap()
            XCTAssertTrue(app.buttons["挂断"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["挂断"].isHittable)
            XCTAssertFalse(app.buttons["拨号"].isHittable)
            toggle.tap()
            XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["拨号"].isHittable)
            XCTAssertTrue(app.buttons["1"].isHittable)
            XCTAssertFalse(app.buttons["挂断"].exists, "Ended call controls must be removed from the restored dial pad")
        }
        toggle.tap()
        XCTAssertTrue(app.buttons["挂断"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["挂断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["挂断"].isHittable)
        toggle.tap()
        XCTAssertTrue(app.buttons["拨号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["拨号"].isHittable)
    }

    @MainActor func testInAppCallKeepsControlsWithoutCustomWaveform() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_DEVICE"] = "1"
        app.launchEnvironment["AIRSIM_UI_DESIGN"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["挂断"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["callAudioLevels"].exists)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["允许"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["挂断"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "249-in-app-call-controls"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testNativeCallKeypadKeepsIdentityAndReturnsToControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_DEVICE"] = "1"
        app.launchEnvironment["AIRSIM_UI_DESIGN"] = "1"
        app.launch()
        defer { app.terminate() }
        dismissMicrophonePrompt()
        XCTAssertTrue(app.buttons["拨号键盘"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["张先生"].exists)
        XCTAssertTrue(app.staticTexts["SIM 2 · 中国移动 · 北京市"].exists)
        XCTAssertFalse(app.buttons["FaceTime通话"].exists)
        app.buttons["拨号键盘"].tap()
        let hide = app.buttons["call.hideKeypad"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"] {
            XCTAssertTrue(app.buttons["发送 DTMF \(key)"].isHittable)
        }
        XCTAssertTrue(hide.isHittable)
        XCTAssertEqual(app.buttons["发送 DTMF 1"].frame.width, min(88, app.frame.width * 0.2), accuracy: 1)
        XCTAssertTrue(app.buttons["挂断"].isHittable)
        XCTAssertTrue(app.staticTexts["张先生"].exists)
        XCTAssertTrue(app.staticTexts["SIM 2 · 中国移动 · 北京市"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "268-native-inline-call-keypad"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        hide.tap()
        XCTAssertTrue(app.buttons["拨号键盘"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["静音"].isHittable)
        XCTAssertTrue(app.buttons["call.audioRoute"].isHittable)
        XCTAssertFalse(app.buttons["发送 DTMF #"].exists)
    }

    @MainActor func testReference10086CallKeypadGeometry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_DEVICE"] = "1"
        app.launchEnvironment["AIRSIM_UI_REGION"] = "1"
        app.launchEnvironment["AIRSIM_UI_REGION_NUMBER"] = "10086"
        app.launch()
        defer { app.terminate() }
        dismissMicrophonePrompt()
        XCTAssertTrue(app.buttons["拨号键盘"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["10086"].exists)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "268-reference-10086-controls"; controls.lifetime = .keepAlways; add(controls)
        app.buttons["拨号键盘"].tap()
        XCTAssertTrue(app.buttons["call.hideKeypad"].waitForExistence(timeout: 5))
        let first = app.buttons["发送 DTMF 1"].frame
        let secondRow = app.buttons["发送 DTMF 4"].frame
        let next = app.buttons["发送 DTMF 2"].frame
        let diameter = min(88, app.frame.width * 0.2)
        XCTAssertEqual(first.width, diameter, accuracy: 1)
        XCTAssertEqual(first.height, diameter, accuracy: 1)
        XCTAssertEqual(secondRow.minY - first.minY, diameter + 19, accuracy: 1)
        XCTAssertEqual(next.midX - first.midX, (app.frame.width - 44) / 3, accuracy: 1)
        XCTAssertTrue(app.buttons["挂断"].isHittable)
        XCTAssertTrue(app.buttons["call.hideKeypad"].isHittable)
        XCTAssertLessThan(app.buttons["发送 DTMF #"].frame.maxY, app.buttons["挂断"].frame.minY)
        let keypad = XCTAttachment(screenshot: app.screenshot())
        keypad.name = "268-reference-10086-keypad"; keypad.lifetime = .keepAlways; add(keypad)
        app.buttons["call.hideKeypad"].tap()
        XCTAssertTrue(app.buttons["拨号键盘"].waitForExistence(timeout: 5))
    }

    @MainActor func testCallMinimizeRestoresKeypadAndPreservesNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_CALL_TRANSITION"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["ui.callTransition"].tap()
        XCTAssertTrue(app.buttons["call.minimize"].waitForExistence(timeout: 10))
        let route = app.buttons["call.audioRoute"].frame
        let minimize = app.buttons["call.minimize"].frame
        let mute = app.buttons["静音"].frame
        XCTAssertEqual(minimize.midX, (route.midX + mute.midX) / 2, accuracy: 1)
        XCTAssertEqual(minimize.minY, mute.minY, accuracy: 1)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "269-call-controls-with-center-minimize"; controls.lifetime = .keepAlways; add(controls)
        app.buttons["拨号键盘"].tap()
        XCTAssertTrue(app.buttons["call.hideKeypad"].waitForExistence(timeout: 5))
        app.buttons["call.minimize"].tap()
        XCTAssertTrue(app.buttons["call.restore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["设置"].isHittable)
        app.buttons["设置"].tap()
        XCTAssertFalse(app.buttons["call.hideKeypad"].isHittable)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "269-collapsed-call-settings"; collapsed.lifetime = .keepAlways; add(collapsed)
        app.buttons["call.restore"].tap()
        XCTAssertTrue(app.buttons["call.hideKeypad"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["发送 DTMF #"].isHittable)
        app.buttons["call.minimize"].tap()
        app.buttons["ui.callTransition"].tap()
        XCTAssertFalse(app.buttons["call.restore"].exists)
        XCTAssertTrue(app.buttons["设置"].isHittable)
        app.buttons["ui.callTransition"].tap()
        XCTAssertTrue(app.buttons["call.minimize"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["call.restore"].exists)
        XCTAssertFalse(app.buttons["call.hideKeypad"].exists)
    }

    @MainActor func testCallAudioOutputChoicesDoNotInterruptCallPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["call.audioRoute"].waitForExistence(timeout: 10))
        app.buttons["call.audioRoute"].tap()
        XCTAssertTrue(app.buttons["挂断"].isHittable)
        XCTAssertTrue(app.buttons["拨号键盘"].isHittable)
        XCTAssertFalse(app.buttons["取消"].exists, "Built-in routes toggle directly without a menu")
    }

    @MainActor func testCompactCallRouteMenuShowsCurrentRouteWithoutMediaPanel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launchEnvironment["AIRSIM_UI_CALL"] = "active"
        app.launchEnvironment["AIRSIM_UI_AUDIO_ROUTES"] = "external"
        app.launch()
        defer { app.terminate() }
        let output = app.buttons["call.systemAudioRoute"]
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        output.tap()
        XCTAssertTrue(app.buttons["AirPods 5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AirPods 5"].isSelected)
        XCTAssertTrue(app.buttons["iPhone"].exists)
        XCTAssertTrue(app.buttons["扬声器"].exists)
        XCTAssertFalse(app.staticTexts["未在播放"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Compact call route menu"; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testRepairPageReportsWithoutDeletingData() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        app.buttons["设置"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["帮助与诊断"].waitForExistence(timeout: 10))
        app.buttons["帮助与诊断"].tap()
        app.buttons["诊断与修复"].tap()
        XCTAssertTrue(app.buttons["一键检查"].waitForExistence(timeout: 5))
        app.buttons["一键检查"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已配对安卓：")).firstMatch.waitForExistence(timeout: 5))
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
        app.buttons["recents.actions"].tap()
        let markRead = app.buttons["recents.markAllSeen"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))
        XCTAssertEqual(markRead.label, "将全部未接来电标为已读")
        let recentShot = XCTAttachment(screenshot: app.screenshot()); recentShot.name = "180-explicit-mark-read"; recentShot.lifetime = .keepAlways; add(recentShot)
        markRead.tap()
        app.buttons["recents.actions"].tap()
        XCTAssertFalse(markRead.isEnabled)
        app.tap()
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
        let appearance = app.buttons["外观与偏好"]
        for _ in 0..<3 where !appearance.isHittable { app.swipeUp() }
        appearance.tap()
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
            XCTAssertTrue(app.buttons["dialpad.delete"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["dialpad.delete"].isHittable)
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
        app.buttons["dialpad.delete"].press(forDuration: 1)
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
        let clear = app.buttons["dialpad.delete"]
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
                app.buttons["拨号键盘"].tap()
                XCTAssertTrue(app.buttons["call.hideKeypad"].waitForExistence(timeout: 5))
                app.swipeUp()
                XCTAssertTrue(app.buttons["发送 DTMF #"].isHittable)
                app.buttons["call.hideKeypad"].tap()
                XCTAssertTrue(action.waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

}
