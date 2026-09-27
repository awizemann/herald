import XCTest

/// A compose window. Queries run over the whole app, which is right while
/// one compose window is open; pass a window as `root` to scope to one.
@MainActor
struct ComposePage {
    let app: XCUIApplication
    var root: XCUIElement?

    private var scope: XCUIElement { root ?? app }

    var to: XCUIElement { scope.element(id: AccessibilityID.Compose.to) }
    var cc: XCUIElement { scope.element(id: AccessibilityID.Compose.cc) }
    var bcc: XCUIElement { scope.element(id: AccessibilityID.Compose.bcc) }
    var subject: XCUIElement { scope.element(id: AccessibilityID.Compose.subject) }
    var body: XCUIElement { scope.element(id: AccessibilityID.Compose.body) }
    var send: XCUIElement { scope.element(id: AccessibilityID.Compose.send) }
    var attach: XCUIElement { scope.element(id: AccessibilityID.Compose.attach) }
    var deleteDraft: XCUIElement { scope.element(id: AccessibilityID.Compose.deleteDraft) }
    var busy: XCUIElement { scope.element(id: AccessibilityID.Compose.busy) }
    /// The error bar's text (``XCUIElement/text`` = message + failure reason); its presence
    /// IS the bar.
    var errorMessage: XCUIElement { scope.element(id: AccessibilityID.Compose.errorMessage) }
    var errorSignIn: XCUIElement { scope.element(id: AccessibilityID.Compose.errorSignIn) }
    var errorSigningIn: XCUIElement { scope.element(id: AccessibilityID.Compose.errorSigningIn) }

    /// The window holding this composer's Send button.
    var window: XCUIElement {
        app.windows.containing(.any, identifier: AccessibilityID.Compose.send).firstMatch
    }

    /// Opens a new composer from the mail window's toolbar and waits for it.
    @discardableResult
    static func openNew(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> ComposePage {
        MailListPage(app: app).composeButton.waitAndClick(file: file, line: line)
        let page = ComposePage(app: app)
        XCTAssertTrue(page.send.waitUntilExists(), "the compose window never opened", file: file, line: line)
        return page
    }

    /// Types into whichever of the fields are given (clicking each first).
    func fill(
        to: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let to { self.to.clickAndType(to, file: file, line: line) }
        if let subject { self.subject.clickAndType(subject, file: file, line: line) }
        if let body { self.body.clickAndType(body, file: file, line: line) }
    }

    /// Raises this compose window through the Window menu (by its title).
    /// Needed after anything in the MAIN window was clicked: the compose
    /// window opens inside the main window's frame, so once the main window
    /// is in front it covers the composer completely and a "click" on a
    /// compose control lands on the main window instead.
    func bringToFront(file: StaticString = #filePath, line: UInt = #line) {
        let title = window.title
        // Clicked WITHOUT opening the menu first: XCUITest opens the menu
        // itself when it clicks a menu item, and a menu the test had already
        // opened gets toggled shut ("open menu during menu traversal").
        app.menuBars.menuBarItems["Window"].menuItems[title].firstMatch.waitAndClick(file: file, line: line)
        XCTAssertTrue(send.waitUntilHittable(), "the compose window \"\(title)\" did not come to the front", file: file, line: line)
    }

    func clickSend(file: StaticString = #filePath, line: UInt = #line) {
        send.waitAndClick(file: file, line: line)
    }

    /// Waits for the error bar offering Sign In (a dead session, no attempt
    /// running).
    @discardableResult
    func waitForSignInOffered(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { errorMessage.exists && errorSignIn.exists && errorSignIn.isEnabled }
    }

    /// Waits until the error bar says `text` (e.g. a sign-in failure reason).
    @discardableResult
    func waitForError(containing text: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        errorMessage.waitForText(timeout: timeout) { $0.contains(text) }
    }

    /// Waits for the error bar and returns its label ("" on timeout).
    @discardableResult
    func waitForError(timeout: TimeInterval = HeraldApp.defaultTimeout) -> String {
        errorMessage.waitForExistence(timeout: timeout) ? errorMessage.text : ""
    }
}

/// The first-run screen, or the Add Account sheet (same view).
@MainActor
struct OnboardingPage {
    let app: XCUIApplication

    var origin: XCUIElement { app.element(id: AccessibilityID.Onboarding.origin) }
    /// Sign In; its label is "Signing in" while one runs.
    var signIn: XCUIElement { app.element(id: AccessibilityID.Onboarding.signIn) }
    var cancel: XCUIElement { app.element(id: AccessibilityID.Onboarding.cancel) }
    var error: XCUIElement { app.element(id: AccessibilityID.Onboarding.error) }
    var progress: XCUIElement { app.element(id: AccessibilityID.Onboarding.progress) }

    /// The fake server the harness serves (`UITestOrigins.primary`).
    static let primaryOrigin = "https://hqbase.uitest.invalid"
    static let secondaryOrigin = "https://second.uitest.invalid"

    /// Waits until the inline error says `text`.
    @discardableResult
    func waitForError(containing text: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        error.waitForText(timeout: timeout) { $0.contains(text) }
    }

    /// Waits for the screen (its origin field).
    @discardableResult
    func waitUntilVisible(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        origin.waitForExistence(timeout: timeout)
    }

    /// Types the origin and presses Sign In.
    func signIn(origin text: String = OnboardingPage.primaryOrigin, file: StaticString = #filePath, line: UInt = #line) {
        origin.clickAndType(text, file: file, line: line)
        signIn.waitAndClick(file: file, line: line)
    }
}

/// The Debug-only "UI Test Controls" menu and the `uitest.status` element.
@MainActor
struct TestControlsPage {
    let app: XCUIApplication

    static let menuTitle = "UI Test Controls"

    var menuBarItem: XCUIElement { app.menuBars.menuBarItems[Self.menuTitle].firstMatch }
    /// The status element; its accessibility VALUE is the `key=value` line.
    var statusElement: XCUIElement { app.element(id: "uitest.status") }

    // MARK: Status

    /// The status as it is NOW, or `nil` when absent/unparseable. Prefer the
    /// waiting forms: counters change asynchronously after a click.
    func currentStatus() -> UITestStatus? {
        guard statusElement.exists else { return nil }
        return UITestStatus(statusElement.stringValue)
    }

    /// Waits for a parseable status satisfying `condition`; returns it, or
    /// `nil` on timeout (assert on that).
    func waitForStatus(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        where condition: (UITestStatus) -> Bool = { _ in true }
    ) -> UITestStatus? {
        Wait.value(timeout: timeout) {
            currentStatus().flatMap { condition($0) ? $0 : nil }
        }
    }

    /// Waits until counter `key` is at least `minimum`.
    func waitForCount(
        _ key: String,
        atLeast minimum: Int,
        timeout: TimeInterval = HeraldApp.defaultTimeout
    ) -> UITestStatus? {
        waitForStatus(timeout: timeout) { ($0.count(key) ?? .min) >= minimum }
    }

    // MARK: Menu

    /// Opens the menu (for tests that want to see it open).
    func open(file: StaticString = #filePath, line: UInt = #line) {
        menuBarItem.waitAndClick(file: file, line: line)
    }

    /// Closes an open menu.
    func closeMenu() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A menu item of the UI Test Controls menu: by identifier when SwiftUI
    /// carried it to the NSMenuItem, else by title.
    func item(id: String, title: String) -> XCUIElement {
        let byID = menuBarItem.menuItems.matching(identifier: id).firstMatch
        return byID.exists ? byID : menuBarItem.menuItems[title].firstMatch
    }

    /// Clicks the item. The menu is NOT opened first: menu items are in the
    /// accessibility tree while the menu is closed, and XCUITest opens the
    /// menu itself to click one — opening it beforehand made that traversal
    /// toggle it shut again ("Not hittable: MenuItem" at an off-screen frame).
    private func choose(id: String, title: String, file: StaticString, line: UInt) {
        let target = Wait.value { () -> XCUIElement? in
            let candidate = item(id: id, title: title)
            return candidate.exists ? candidate : nil
        }
        guard let target else {
            XCTFail("UI Test Controls item \(id) / \"\(title)\" not found", file: file, line: line)
            closeMenu()
            return
        }
        target.click()
    }

    func setServer(_ state: UITestServerState, file: StaticString = #filePath, line: UInt = #line) {
        choose(id: "uitest.server.\(state.rawValue)", title: "Server: \(state.rawValue)", file: file, line: line)
        XCTAssertNotNil(
            waitForStatus { $0.server == state.rawValue },
            "server never switched to \(state.rawValue)", file: file, line: line
        )
    }

    /// `.fail` from the menu always uses the harness's default reason.
    func setPresenter(_ mode: UITestPresenterMode, file: StaticString = #filePath, line: UInt = #line) {
        choose(
            id: "uitest.presenter.\(mode.statusName)",
            title: "Sign-in: \(mode.statusName)",
            file: file, line: line
        )
        XCTAssertNotNil(
            waitForStatus { $0.presenter == mode.statusName },
            "presenter never switched to \(mode.statusName)", file: file, line: line
        )
    }

    /// Completes every sign-in parked by `hangUntilCancelled`.
    func completePendingSignIns(file: StaticString = #filePath, line: UInt = #line) {
        choose(id: "uitest.presenter.completePending", title: "Sign-in: complete pending", file: file, line: line)
    }

    /// `true` makes every account activation fail after consent (Add
    /// Account's "could not bring the account up").
    func setActivationRefused(_ refused: Bool, file: StaticString = #filePath, line: UInt = #line) {
        if refused {
            choose(id: "uitest.activation.refuse", title: "Activation: refuse", file: file, line: line)
        } else {
            choose(id: "uitest.activation.healthy", title: "Activation: healthy", file: file, line: line)
        }
        XCTAssertNotNil(
            waitForStatus { $0.activationRefused == refused },
            "activation never switched to refused=\(refused)", file: file, line: line
        )
    }

    func setAccountStoreRefusesList(_ refuses: Bool, file: StaticString = #filePath, line: UInt = #line) {
        if refuses {
            choose(id: "uitest.store.refuseList", title: "Account store: refuse account list", file: file, line: line)
        } else {
            choose(id: "uitest.store.healthy", title: "Account store: healthy", file: file, line: line)
        }
        XCTAssertNotNil(
            waitForStatus { $0.storeRefusesList == refuses },
            "account store never switched to refusesList=\(refuses)", file: file, line: line
        )
    }

    /// Zeroes the counters and waits until the status shows it.
    func resetCounters(file: StaticString = #filePath, line: UInt = #line) {
        choose(id: "uitest.resetCounters", title: "Reset counters", file: file, line: line)
        XCTAssertNotNil(
            waitForStatus { $0.sends == 0 && $0.sendRequests == 0 && $0.refreshes == 0 && $0.signIns == 0 },
            "the counters never reset", file: file, line: line
        )
    }
}
