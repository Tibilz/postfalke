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
    }

    private func launch(server: String) {
        // A short undo window keeps the tests fast.
        app.launchArguments = ["-resetState", "-testServer", server, "-undoSendDelay", "8", "-AppleLanguages", "(de)"]
        app.launch()
    }

    /// Welcome screen → account form with name, address and password filled in.
    private func fillAccountForm(email: String = "tester@example.org", password: String = "geheim123") {
        XCTAssertTrue(app.staticTexts["Willkommen bei Postfalke"].waitForExistence(timeout: 10))
        // Right after launch a tap can get lost; try again until the form is there.
        for _ in 0..<3 where !app.textFields["Dein Name"].exists {
            app.buttons["E-Mail-Konto einrichten"].tap()
            _ = app.textFields["Dein Name"].waitForExistence(timeout: 4)
        }
        type("Tina Tester", into: app.textFields["Dein Name"])
        type(email, into: app.textFields["E-Mail-Adresse"])
        type(password, into: app.secureTextFields["Passwort"])
    }

    private func value(_ identifier: String) -> String {
        (element(identifier).value as? String) ?? ""
    }

    /// Back to "Postfächer", then into a folder.
    private func openFolder(_ title: String) {
        for _ in 0..<3 where !app.navigationBars["Postfächer"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let folder = app.staticTexts[title].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
    }

    /// Waits until a row with this text shows up, reloading the folder in between.
    private func waitForRow(_ text: String, in folder: String, present: Bool = true) -> Bool {
        for _ in 0..<5 {
            openFolder(folder)
            if present ? app.staticTexts[text].waitForExistence(timeout: 6) : !app.staticTexts[text].waitForExistence(timeout: 3) {
                return true
            }
        }
        return false
    }

    private func compose(subject: String, body: String) {
        app.buttons["Verfassen"].firstMatch.tap()
        type("tester@example.org", into: element("compose.to"))
        type(subject, into: element("compose.subject"))
        type(body, into: element("compose.body"))
    }

    /// Undo send, scheduled send via the outbox, and drafts on the server.
    func testUndoScheduleAndDrafts() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_PLAIN"] != "0" else { throw XCTSkip("plain server not requested") }
        launch(server: "21143,21025")
        fillAccountForm()
        app.buttons["Sichern"].tap()
        XCTAssertTrue(app.staticTexts["Testnachricht 3 (mit Klammer)"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()

        // 1. Send, withdraw: the message comes back for editing.
        compose(subject: "Widerruf-Test", body: "Zurückgeholt")
        app.buttons["Senden"].tap()
        let undo = app.buttons["Senden widerrufen"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        shot("p1-01-widerrufen")
        undo.tap()
        XCTAssertTrue(element("compose.subject").waitForExistence(timeout: 5))
        XCTAssertEqual(value("compose.subject"), "Widerruf-Test")

        // 2. Send again and let the window pass: it arrives.
        app.buttons["Senden"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForRow("Widerruf-Test", in: "Posteingang"))

        // 3. Schedule for tomorrow: it waits in the outbox until "Jetzt senden".
        compose(subject: "Morgen-Mail", body: "Morgen früh")
        app.buttons["Senden"].press(forDuration: 1.5)
        let tomorrow = app.buttons["Morgen, 8:00"]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 5))
        tomorrow.tap()
        openFolder("Postausgang")
        let planned = app.staticTexts["Morgen-Mail"]
        XCTAssertTrue(planned.waitForExistence(timeout: 5))
        shot("p1-02-postausgang")
        planned.swipeLeft()
        app.buttons["Jetzt senden"].tap()
        XCTAssertTrue(waitForRow("Morgen-Mail", in: "Posteingang"))

        // 4. Save a draft, reopen, change and save again: still one draft.
        compose(subject: "Mein Entwurf", body: "Version eins")
        app.buttons["Abbrechen"].tap()
        app.buttons["Entwurf sichern"].tap()
        XCTAssertTrue(waitForRow("Mein Entwurf", in: "Entwürfe"))
        shot("p1-03-entwuerfe")
        // Saved on the server, so it must not also linger as a device-only draft
        // (the outbox is empty here, so its row must not show up at all).
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<3 where !app.navigationBars["Postfächer"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertFalse(app.staticTexts["Postausgang"].exists)
        openFolder("Entwürfe")
        app.staticTexts["Mein Entwurf"].tap()
        XCTAssertTrue(element("compose.subject").waitForExistence(timeout: 10))
        XCTAssertEqual(value("compose.subject"), "Mein Entwurf")
        XCTAssertTrue(value("compose.body").contains("Version eins"))
        type(" und zwei", into: element("compose.body"))
        app.buttons["Abbrechen"].tap()
        app.buttons["Entwurf sichern"].tap()
        XCTAssertTrue(waitForRow("Mein Entwurf", in: "Entwürfe"))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Mein Entwurf").count, 1)

        // 5. Sending the draft removes it from the Drafts folder.
        app.staticTexts["Mein Entwurf"].tap()
        XCTAssertTrue(element("compose.body").waitForExistence(timeout: 10))
        XCTAssertTrue(value("compose.body").contains("und zwei"))
        app.buttons["Senden"].tap()
        XCTAssertTrue(waitForRow("Mein Entwurf", in: "Posteingang"))
        XCTAssertTrue(waitForRow("Mein Entwurf", in: "Entwürfe", present: false))
    }

    /// Switches a service of the test server off or on (see Tools/fakemail.py).
    private func server(_ service: String, up: Bool) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:21080/control/\(service)-\(up ? "up" : "down")")!)
        request.httpMethod = "POST"
        let done = expectation(description: "control")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    /// Server unreachable: cached mail stays readable, changes and outgoing mail wait and go through later.
    func testOfflineCacheAndQueue() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_PLAIN"] != "0" else { throw XCTSkip("plain server not requested") }
        server("imap", up: true)
        server("smtp", up: true)
        launch(server: "21143,21025")
        fillAccountForm()
        app.buttons["Sichern"].tap()
        XCTAssertTrue(app.staticTexts["Testnachricht 3 (mit Klammer)"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()
        Thread.sleep(forTimeInterval: 3)   // let the inbox be downloaded for offline reading

        server("imap", up: false)
        server("smtp", up: false)
        defer { server("imap", up: true); server("smtp", up: true) }

        // Restart without network to the server: the list comes from the device.
        app.terminate()
        app.launchArguments = ["-undoSendDelay", "0", "-AppleLanguages", "(de)"]
        app.launch()
        openFolder("Posteingang")
        XCTAssertTrue(app.staticTexts["Testnachricht 1 (mit Klammer)"].waitForExistence(timeout: 10))
        shot("p2-01-offline-liste")

        // A downloaded message opens.
        app.staticTexts["Testnachricht 2 (mit Klammer)"].tap()
        XCTAssertTrue(webText("Inhalt 2").waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Flag a message while offline; it must survive the next sync from the server.
        let first = app.staticTexts["Testnachricht 1 (mit Klammer)"]
        first.swipeLeft()
        app.buttons["Markieren"].tap()

        // Sending fails and waits in the outbox.
        compose(subject: "Offline gesendet", body: "Kam später an")
        app.buttons["Senden"].tap()
        openFolder("Postausgang")
        let waiting = app.staticTexts["Offline gesendet"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        shot("p2-02-postausgang-offline")

        // Server back: the outbox sends, the flag reaches the server.
        server("imap", up: true)
        server("smtp", up: true)
        waiting.swipeLeft()
        app.buttons["Jetzt senden"].tap()
        XCTAssertTrue(waitForRow("Offline gesendet", in: "Posteingang"))

        // A fresh start re-reads the flags from the server: the offline change is there.
        app.terminate()
        app.launch()
        openFolder("Posteingang")
        XCTAssertTrue(app.staticTexts["Testnachricht 1 (mit Klammer)"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        let flagged = app.cells.containing(.staticText, identifier: "Testnachricht 1 (mit Klammer)").images["Markiert"]
        XCTAssertTrue(flagged.waitForExistence(timeout: 10))
    }

    /// A reply joins its original in one conversation row; the conversation shows both.
    func testConversation() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_PLAIN"] != "0" else { throw XCTSkip("plain server not requested") }
        launch(server: "21143,21025")
        fillAccountForm()
        app.buttons["Sichern"].tap()
        XCTAssertTrue(app.staticTexts["Testnachricht 3 (mit Klammer)"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()

        compose(subject: "Gesprächsthema", body: "Erste Nachricht")
        app.buttons["Senden"].tap()
        XCTAssertTrue(waitForRow("Gesprächsthema", in: "Posteingang"))

        // Reply from the message view.
        app.staticTexts["Gesprächsthema"].tap()
        XCTAssertTrue(webText("Erste Nachricht").waitForExistence(timeout: 10))
        app.buttons["Antworten"].firstMatch.tap()
        app.buttons["Antworten"].firstMatch.tap()   // the menu entry
        type("Zweite Nachricht", into: element("compose.body"))
        // As in Mail, the answer goes above the quote.
        XCTAssertTrue(value("compose.body").hasPrefix("Zweite Nachricht"), value("compose.body"))
        app.buttons["Senden"].tap()

        // One row with "2", opening shows both messages.
        let count = app.staticTexts["2 E-Mails"].firstMatch
        for _ in 0..<5 where !count.exists {
            openFolder("Posteingang")
            _ = count.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(count.exists)
        // The preview shows the answer, not the "… schrieb:" line.
        XCTAssertTrue(app.staticTexts["Zweite Nachricht"].exists)
        shot("p4-01-liste")
        app.staticTexts["Re: Gesprächsthema"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 E-Mails"].waitForExistence(timeout: 10))
        XCTAssertTrue(webText("Zweite Nachricht").waitForExistence(timeout: 10))
        shot("p4-02-gespraech")
        // The older message opens on tap.
        let older = app.staticTexts["Erste Nachricht"].firstMatch
        if older.exists { older.tap() }
        XCTAssertTrue(webText("Erste Nachricht").waitForExistence(timeout: 10))

        // Writing again: the address is suggested and becomes a chip.
        app.buttons["Verfassen"].firstMatch.tap()
        type("tes", into: element("compose.to"))
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS 'tester@example.org'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        shot("p5-01-vorschlag")
        suggestion.tap()
        XCTAssertTrue(app.buttons["Tina Tester"].waitForExistence(timeout: 5))
        XCTAssertEqual(value("compose.to"), "")
        shot("p5-02-chip")

        // Throw this one away, then open a link: the compose sheet comes prefilled.
        app.buttons["Abbrechen"].tap()
        app.buttons["Entwurf löschen"].tap()
        XCUIDevice.shared.system.open(URL(string: "postfalke://compose?to=link@example.org&subject=Aus%20einem%20Link")!)
        XCTAssertTrue(element("compose.subject").waitForExistence(timeout: 10))
        XCTAssertEqual(value("compose.subject"), "Aus einem Link")
        XCTAssertTrue(app.buttons["link@example.org"].exists)
    }

    /// Provider hint for Gmail addresses, and a login error that can be copied.
    func testLoginHintAndCopyableError() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_PLAIN"] != "0" else { throw XCTSkip("plain server not requested") }
        launch(server: "21143,21025")
        fillAccountForm(email: "tina.tester@gmail.com", password: "falsch")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'App-Passwort'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["App-Passwort erstellen"].exists || app.buttons["App-Passwort erstellen"].exists)
        app.buttons["Sichern"].tap()

        let copy = app.buttons["Fehler kopieren"]
        XCTAssertTrue(copy.waitForExistence(timeout: 20))
        for _ in 0..<6 where !copy.isHittable { app.swipeUp(velocity: .slow) }
        // Selectable text is not a plain static text for XCUITest, so match any element type.
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Anmeldung fehlgeschlagen' OR value CONTAINS 'Anmeldung fehlgeschlagen'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        shot("login-fehler")
        copy.tap()
        XCTAssertTrue(app.buttons["Kopiert"].waitForExistence(timeout: 5))
    }

    /// Server with a self-signed certificate (Tools/fakemail.py with FAKEMAIL_TLS_CERT,
    /// IMAP 21993, SMTP 21465, CardDAV 21443). Needs MAIL_TEST_TLS=1.
    func testSelfSignedCertificates() throws {
        guard ProcessInfo.processInfo.environment["MAIL_TEST_TLS"] == "1" else { throw XCTSkip("no TLS test server") }
        launch(server: "21993,21465,tls")
        fillAccountForm()
        app.buttons["Sichern"].tap()

        // IMAP and SMTP each ask once; afterwards the account is saved.
        let alert = app.alerts["Zertifikat nicht vertrauenswürdig"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '127.0.0.1:21993'")).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'nextcloud.local'")).firstMatch.exists)
        shot("tls-01-imap")
        alert.buttons["Diesem Zertifikat vertrauen"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '127.0.0.1:21465'")).firstMatch.exists)
        alert.buttons["Diesem Zertifikat vertrauen"].tap()

        XCTAssertTrue(app.staticTexts["Testnachricht 3 (mit Klammer)"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()
        shot("tls-02-posteingang")

        // CardDAV on the same server
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Einstellungen"].tap()
        app.staticTexts["Schlüssel aus Kontakten"].tap()
        type("https://127.0.0.1:21443/dav/", into: app.textFields["https://cloud.example.org/remote.php/dav"])
        type("tester@example.org", into: app.textFields["Benutzername"])
        type("geheim123", into: app.secureTextFields.firstMatch)
        app.buttons["Sichern und synchronisieren"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '127.0.0.1:21443'")).firstMatch.exists)
        shot("tls-03-carddav-frage")
        alert.buttons["Diesem Zertifikat vertrauen"].tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Kontakte gelesen'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Eigenes Zertifikat vertraut"].exists)
        shot("tls-04-carddav-ok")
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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
        guard ProcessInfo.processInfo.environment["MAIL_TEST_PLAIN"] != "0" else { throw XCTSkip("plain server not requested") }
        // 1. Account setup
        launch(server: "21143,21025")
        XCTAssertTrue(app.staticTexts["Willkommen bei Postfalke"].waitForExistence(timeout: 10))
        shot("01-willkommen")
        fillAccountForm()

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
        let to = element("compose.to")
        type(withContacts ? "tester@example.org, carla@example.org" : "tester@example.org", into: to)
        let subject = element("compose.subject")
        type("Streng geheim", into: subject)
        app.buttons["compose.sign"].tap()
        app.buttons["compose.encrypt"].tap()
        XCTAssertTrue(app.buttons["compose.protectSubject"].waitForExistence(timeout: 5))
        shot("07a-verschluesseln-an")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Kein öffentlicher Schlüssel'")).firstMatch.exists)
        let body = element("compose.body")
        type("Hallo vom UI-Test", into: body)
        shot("07-verfassen")
        app.buttons["Senden"].tap()

        // 7. On the server the subject is "..."; opening decrypts, verifies and reveals it
        XCTAssertTrue(app.buttons["Verfassen"].waitForExistence(timeout: 20))
        let row = app.staticTexts["Betreff verschlüsselt"]
        for _ in 0..<3 where !row.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.staticTexts["Posteingang"].firstMatch.tap()
            _ = row.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.staticTexts["Streng geheim"].exists)
        shot("08-posteingang-verschluesselt")
        row.tap()
        let security = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Verschlüsselt' AND label CONTAINS 'Signatur gültig'")).firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 15))
        security.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Signiert von Tina Tester'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Streng geheim"].exists)
        XCTAssertTrue(webText("Hallo vom UI-Test").waitForExistence(timeout: 10))
        shot("09-entschluesselt")

        // 8. Back in the list the real subject is shown from now on
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Streng geheim"].waitForExistence(timeout: 10))
        shot("10-posteingang-betreff")
    }
}
