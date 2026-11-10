import XCTest

/// Drives the real app against Tools/fakemail.py:
///   python3 Tools/fakemail.py 21143 21025 geheim123
/// Skipped unless the test runner sees MAIL_TEST_SERVER=1
/// (pass TEST_RUNNER_MAIL_TEST_SERVER=1 to xcodebuild).
final class EndToEndTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_SERVER"] == "1" else {
            throw XCTSkip("local test server not running")
        }
        continueAfterFailure = false
        app.launchArguments = ["-resetState", "-testServer", "21143,21025", "-AppleLanguages", "(de)"]
        app.launch()
    }

    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            shot("fehler")
            if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
                try? app.debugDescription.write(toFile: directory + "/fehler.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    /// iOS may offer to save the typed password; decline.
    private func dismissPasswordPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for candidate in [app.buttons["Später"], springboard.buttons["Später"], app.buttons["Not Now"], springboard.buttons["Not Now"]]
            where candidate.exists {
                // The sheet animates in; tap until it is really gone.
                for _ in 0..<5 where candidate.exists {
                    if candidate.isHittable { candidate.tap() }
                    Thread.sleep(forTimeInterval: 1.2)
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func webText(_ text: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps until the field really has keyboard focus, then types.
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Bring the field clear of the navigation bar and the keyboard.
        for _ in 0..<8 where !field.isHittable || field.frame.minY > 420 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        for _ in 0..<8 where field.frame.minY < 150 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        for _ in 0..<6 {
            field.tap()
            Thread.sleep(forTimeInterval: 0.7)
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }

    func testAccountKeyAndEncryptedMail() throws {
        // 1. Account setup
        XCTAssertTrue(app.staticTexts["Willkommen bei Postfalke"].waitForExistence(timeout: 10))
        shot("01-willkommen")
        app.buttons["E-Mail-Konto einrichten"].tap()

        let name = app.textFields["Dein Name"]
        type("Tina Tester", into: name)
        let email = app.textFields["E-Mail-Adresse"]
        type("tester@example.org", into: email)
        let password = app.secureTextFields["Passwort"]
        type("geheim123", into: password)

        shot("02-konto")
        app.buttons["Sichern"].tap()

        // 2. Inbox shows the server's messages
        XCTAssertTrue(app.staticTexts["Testnachricht 3 (mit Klammer)"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()
        shot("03-posteingang")

        // 3. Read a plain message
        app.staticTexts["Testnachricht 2 (mit Klammer)"].tap()
        XCTAssertTrue(webText("Inhalt 2").waitForExistence(timeout: 15))
        shot("04-nachricht")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 4. Generate a key pair
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to the folder list
        XCTAssertTrue(app.staticTexts["Papierkorb"].waitForExistence(timeout: 10))
        shot("05-ordner")
        app.buttons["Einstellungen"].tap()
        app.staticTexts["Schlüsselverwaltung"].tap()
        app.buttons["Hinzufügen"].tap()
        app.buttons["Neues Schlüsselpaar erzeugen"].tap()
        XCTAssertTrue(app.buttons["Erzeugen"].waitForExistence(timeout: 5))
        app.buttons["Erzeugen"].tap()
        XCTAssertTrue(app.staticTexts["Tina Tester <tester@example.org>"].waitForExistence(timeout: 20))
        shot("06-schluessel")
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to the settings root
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5))
        app.buttons["Fertig"].tap()

        // 5. Keys from CardDAV contacts (needs the server's CardDAV port and a card with a key,
        //    see README). The card is for carla@example.org, the key's own user ID says alt@example.org.
        let withContacts = ProcessInfo.processInfo.environment["MAIL_TEST_DAV"] == "1"
        if withContacts {
            app.buttons["Einstellungen"].tap()
            app.staticTexts["Schlüssel aus Kontakten"].tap()
            type("http://127.0.0.1:21080/dav/", into: app.textFields["https://cloud.example.org/remote.php/dav"])
            type("tester@example.org", into: app.textFields["Benutzername"])
            type("geheim123", into: app.secureTextFields.firstMatch)
            app.buttons["Sichern und synchronisieren"].tap()
            let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Kontakte gelesen'")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["carla@example.org"].waitForExistence(timeout: 5))
            shot("06b-kontakte")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.buttons["Fertig"].tap()
        }

        // 6. Send an encrypted and signed mail (subject included) to ourselves
        app.staticTexts["Posteingang"].tap()
        app.buttons["Verfassen"].tap()
        let to = app.textFields["name@example.org"].firstMatch
        type(withContacts ? "tester@example.org, carla@example.org" : "tester@example.org", into: to)
        let subject = app.textFields["Betreff"]
        type("Streng geheim", into: subject)
        app.switches.matching(NSPredicate(format: "label == 'Signieren'")).firstMatch.switches.firstMatch.tap()
        app.switches.matching(NSPredicate(format: "label == 'Verschlüsseln'")).firstMatch.switches.firstMatch.tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label == 'Betreff verschlüsseln'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Kein öffentlicher Schlüssel'")).firstMatch.exists)
        let body = app.textViews.firstMatch
        type("Hallo vom UI-Test", into: body)
        shot("07-verfassen")
        app.buttons["Senden"].tap()

        // 7. On the server the subject is "..."; opening decrypts, verifies and reveals it
        XCTAssertTrue(app.buttons["Verfassen"].waitForExistence(timeout: 20))
        let row = app.staticTexts["..."]
        for _ in 0..<3 where !row.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.staticTexts["Posteingang"].firstMatch.tap()
            _ = row.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.staticTexts["Streng geheim"].exists)
        shot("08-posteingang-verschluesselt")
        row.tap()
        XCTAssertTrue(app.staticTexts["Verschlüsselte Nachricht"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Gültige Signatur"].exists)
        XCTAssertTrue(app.staticTexts["Streng geheim"].exists)
        XCTAssertTrue(webText("Hallo vom UI-Test").waitForExistence(timeout: 10))
        shot("09-entschluesselt")

        // 8. Back in the list the real subject is shown from now on
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Streng geheim"].waitForExistence(timeout: 10))
        shot("10-posteingang-betreff")
    }
}
