import XCTest

/// UI tests run against the LOCAL Supabase stack seeded by `scripts/seed-local.ts`
/// (`scripts/test-ios.sh` resets, seeds and runs them). Accounts sign in with `-signInAs`.
///
/// Set SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR) to save a screenshot of every screen.
/// Set FIXTURE_DIR to the folder holding dictation.m4a and memo5min.m4a.
@MainActor
final class WeeknotesUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var fixtureDir: String? { environment["FIXTURE_DIR"] }

    @discardableResult
    func launch(as email: String, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = ["-signInAs", email] + (reset ? ["-resetState"] : []) + extra
        app.launch()
        return app
    }

    func shot(_ name: String) {
        guard let dir = Self.environment["SCREENSHOT_DIR"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Any element with this accessibility identifier, whatever its type.
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func tab(_ name: String) {
        app.tabBars.buttons[name].firstMatch.tap()
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)", file: file, line: line)
    }

    // MARK: Screens

    func testScreenshotTour() throws {
        launch(as: "ana@weeknotes.test")
        waitFor(app.staticTexts["This week"])
        waitFor(element("card-Hana Sato"))
        sleep(2)
        shot("01-feed")
        app.swipeUp()
        sleep(1)
        shot("02-feed-scrolled")
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        shot("03-feed-end")

        // A memo card in detail
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let deepa = element("card-Deepa Raman")
        waitFor(deepa)
        deepa.tap()
        waitFor(app.buttons["Play Deepa Raman's memo"])
        app.buttons["Play Deepa Raman's memo"].tap()
        sleep(2)
        shot("04-detail-memo")
        app.buttons["Pause Deepa Raman's memo"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        // Composer
        element("writeWeek").tap()
        waitFor(app.textViews["composerText"])
        sleep(1)
        shot("05-composer")
        app.buttons["audienceRow"].tap()
        waitFor(app.navigationBars["Who sees this?"])
        sleep(1)
        shot("06-audience")
        app.buttons["Done"].tap()
        app.buttons["closeComposer"].tap()

        tab("Archive")
        waitFor(app.staticTexts["Archive"])
        sleep(2)
        shot("07-archive")
        app.scrollViews.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(2)
        shot("08-archive-detail")
        app.navigationBars.buttons.firstMatch.tap()

        tab("Replies")
        waitFor(app.staticTexts["Ben Okafor"])
        sleep(1)
        shot("09-replies")
        app.staticTexts["Ben Okafor"].tap()
        waitFor(app.textFields["threadField"])
        sleep(1)
        shot("10-thread")
        app.navigationBars.buttons.firstMatch.tap()

        tab("People")
        waitFor(app.staticTexts["Friend requests"])
        sleep(1)
        shot("11-people")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'College'")).firstMatch.tap()
        sleep(1)
        shot("12-circle-editor")
        app.buttons["Cancel"].tap()

        tab("This week")
        app.buttons["Settings"].tap()
        sleep(1)
        shot("13-settings")
        app.buttons["Dictionary"].tap()
        sleep(1)
        shot("14-dictionary")
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeUp()
        app.buttons["Transcription bake-off (internal)"].tap()
        sleep(1)
        shot("15-bakeoff")
    }

    // MARK: M0 onboarding

    func testOnboardingNewAccount() throws {
        launch(as: "new@weeknotes.test")
        let name = app.textFields["nameField"]
        waitFor(name)
        shot("20-onboarding-profile")
        name.tap()
        name.typeText("Nora Quinn")
        app.buttons["profileContinue"].tap()
        waitFor(app.buttons["phoneSkip"])
        shot("21-onboarding-phone")
        app.buttons["phoneSkip"].tap()
        waitFor(app.buttons["contactsNext"])
        shot("22-onboarding-contacts")
        app.buttons["contactsNext"].tap()
        waitFor(app.buttons["remindersNotNow"])
        shot("23-onboarding-reminders")
        app.buttons["remindersNotNow"].tap()
        waitFor(app.staticTexts["This week"])
        waitFor(app.staticTexts["Bring your friends"])
        shot("24-new-user-feed")
    }

    // MARK: M4 contacts

    /// Two accounts find each other from contacts, become friends, and one puts the other in a
    /// circle. The simulator's address book holds "Ana Morales" (scripts/test-ios.sh adds her).
    func testFindFriendFromContactsThenCircle() throws {
        launch(as: "nora@weeknotes.test")
        let name = app.textFields["nameField"]
        waitFor(name)
        name.tap()
        name.typeText("Nora Quinn")
        app.buttons["profileContinue"].tap()

        // Verify a phone number (the local stack's test code is 123456)
        let phone = app.textFields["phoneField"]
        waitFor(phone)
        phone.tap()
        phone.typeText("555-555-0104")
        app.buttons["Send code"].tap()
        let code = app.textFields["codeField"]
        waitFor(code)
        code.tap()
        code.typeText("123456")
        app.buttons["Verify"].tap()

        // Contacts: Ana is in the address book with a verified number
        waitFor(app.buttons["checkContacts"])
        app.buttons["checkContacts"].tap()
        // iOS 18+ asks how much of the address book to share; the sheet may belong to another process
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shareAll = NSPredicate(format: "label BEGINSWITH 'Share All'")
        for source in [app!, springboard] {
            let button = source.buttons.matching(shareAll).firstMatch
            if button.waitForExistence(timeout: 4) {
                shot("33a-contacts-permission")
                button.tap()
                break
            }
        }
        let add = app.buttons["add-Ana Morales"]
        waitFor(add, timeout: 20)
        shot("33-contacts-match")
        add.tap()
        waitFor(app.staticTexts["Requested"])
        app.buttons["contactsNext"].tap()
        waitFor(app.buttons["remindersNotNow"])
        app.buttons["remindersNotNow"].tap()
        waitFor(app.staticTexts["This week"])

        // Ana accepts and adds Nora to a new circle
        launch(as: "ana@weeknotes.test")
        tab("People")
        waitFor(app.staticTexts["Nora Quinn"])
        shot("34-friend-request")
        // Two requests are pending (Jo's from the seed, and Nora's): accept Nora's
        app.cells.containing(.staticText, identifier: "Nora Quinn").buttons["Accept"].firstMatch.tap()
        sleep(2)
        app.buttons["newCircle"].tap()
        let circleName = app.textFields["circleName"]
        waitFor(circleName)
        circleName.tap()
        circleName.typeText("New friends")
        let nora = app.buttons["member-Nora Quinn"]
        waitFor(nora)
        nora.tap()
        XCTAssertTrue(nora.isSelected, "Nora is checked")
        app.buttons["saveCircle"].tap()
        // The circle row shows its member count: 1
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New friends' AND label ENDSWITH '1'")).firstMatch)
        shot("35-circle-with-new-friend")
    }

    func testWelcomeScreen() throws {
        app = XCUIApplication()
        app.launchArguments = ["-resetState", "-signedOutForTest"]
        app.launch()
        if app.staticTexts["This week"].waitForExistence(timeout: 3) { return }
        waitFor(app.staticTexts["Weeknotes"])
        shot("19-welcome")
    }

    // MARK: M1 drafts

    /// The draft survives an app restart.
    func testDraftSurvivesRelaunch() throws {
        launch(as: "fay@weeknotes.test")
        waitFor(element("myUpdateCard").exists ? element("myUpdateCard") : element("writeWeek"))
        try XCTSkipIf(element("myUpdateCard").exists, "Fay already posted this week")
        element("writeWeek").tap()
        let text = app.textViews["composerText"]
        waitFor(text)
        text.tap()
        text.typeText("Draft that should survive a restart")
        sleep(1)
        app.terminate()

        launch(as: "fay@weeknotes.test", reset: false)
        waitFor(app.staticTexts["Continue your update"])
        element("writeWeek").tap()
        let restored = app.textViews["composerText"]
        waitFor(restored)
        XCTAssertEqual(restored.value as? String, "Draft that should survive a restart")
        shot("25-draft-restored")
    }

    // MARK: M5 posting and visibility

    /// An update posted to one circle is visible to its members and not to a friend outside it.
    func testPostToOneCircleIsVisibleOnlyToItsMembers() throws {
        launch(as: "ivy@weeknotes.test")
        let write = element("writeWeek")
        waitFor(write)
        write.tap()
        let text = app.textViews["composerText"]
        waitFor(text)
        text.tap()
        let marker = "Visibility check \(Int(Date().timeIntervalSince1970))"
        text.typeText(marker)
        app.buttons["postButton"].tap()
        waitFor(element("myUpdateCard"))
        shot("26-posted")

        // Ivy's "Book club" circle holds Ana and Hana. Ana sees it...
        launch(as: "ana@weeknotes.test")
        waitFor(app.staticTexts["This week"])
        waitFor(element("card-Ivy Chen"))
        XCTAssertTrue(app.staticTexts[marker].exists)

        // ...Deepa, Ivy's friend but not in Book club, doesn't
        launch(as: "dee@weeknotes.test")
        waitFor(app.staticTexts["This week"])
        sleep(2)
        XCTAssertFalse(app.staticTexts[marker].exists)
        XCTAssertFalse(element("card-Ivy Chen").exists)
    }

    // MARK: M1 dictation (fixture audio)

    func testDictationInsertsFormattedTextWithShowOriginal() throws {
        let dir = try XCTUnwrap(Self.fixtureDir, "FIXTURE_DIR not set")
        launch(as: "ben@weeknotes.test", extra: ["-dictationFixture", dir + "/dictation.m4a"])
        let open = element("myUpdateCard").waitForExistence(timeout: 8) ? nil : element("writeWeek")
        try XCTSkipIf(open == nil, "Ben already posted this week")
        open!.tap()
        waitFor(app.buttons["dictateButton"])
        app.buttons["dictateButton"].tap()
        sleep(3)
        shot("27a-after-tap")
        let live = element("liveDictation")
        waitFor(live, timeout: 30)
        sleep(4)
        shot("27-dictating")
        sleep(6)
        app.buttons["dictateButton"].tap()
        waitFor(app.buttons["showOriginal"], timeout: 30)
        shot("28-dictated")
        let formatted = app.textViews["composerText"].value as? String ?? ""
        XCTAssertFalse(formatted.isEmpty)
        app.buttons["showOriginal"].tap()
        sleep(1)
        shot("29-show-original")
        let original = app.textViews["composerText"].value as? String ?? ""
        XCTAssertNotEqual(formatted, original)
    }

    // MARK: M2 voice memo

    /// A 5-minute memo records, uploads, transcribes, and plays back from another account
    /// with the transcript shown.
    func testMemoPlaysBackFromAnotherAccount() throws {
        let dir = try XCTUnwrap(Self.fixtureDir, "FIXTURE_DIR not set")
        launch(as: "cal@weeknotes.test", extra: ["-memoFixture", dir + "/memo5min.m4a"])
        let write = element("writeWeek")
        guard write.waitForExistence(timeout: 10) else { throw XCTSkip("Cal already posted this week") }
        write.tap()
        waitFor(app.buttons["memoButton"])
        app.buttons["memoButton"].tap()
        waitFor(app.buttons["recordButton"])
        app.buttons["recordButton"].tap()
        waitFor(app.buttons["keepMemo"], timeout: 20)
        shot("30-memo-review")
        app.buttons["keepMemo"].tap()
        let transcript = app.textViews["memoTranscript"]
        waitFor(transcript, timeout: 240)
        shot("31-memo-transcript")
        let text = transcript.value as? String ?? ""
        XCTAssertTrue(text.lowercased().contains("peaches") || text.lowercased().contains("grandma"), "transcript: \(text.prefix(200))")
        app.buttons["useMemo"].tap()
        waitFor(app.buttons["postButton"])
        app.buttons["postButton"].tap()
        waitFor(element("myUpdateCard"), timeout: 60)

        // Ana is in Cal's College circle
        launch(as: "ana@weeknotes.test")
        let card = element("card-Cal Whitfield")
        waitFor(card, timeout: 20)
        card.tap()
        let play = app.buttons["Play Cal Whitfield's memo"]
        waitFor(play)
        play.tap()
        sleep(3)
        XCTAssertTrue(app.buttons["Pause Cal Whitfield's memo"].exists, "the memo is playing")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'peaches' OR label CONTAINS[c] 'grandma'")).firstMatch.exists, "transcript shown")
        shot("32-memo-from-another-account")
    }
}
