import XCTest

/// The re-auth banner above the mail window.
@MainActor
struct BannerPage {
    let app: XCUIApplication

    var container: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.container) }
    /// Combined text element: ``XCUIElement/text`` = message (+ the failure
    /// reason line) — a StaticText whose words are its VALUE, label empty.
    var message: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.message) }
    var signIn: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.signIn) }
    /// Present only while an attempt runs.
    var cancel: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.cancel) }

    /// The banner's message label ("" when absent).
    var messageText: String { message.exists ? message.text : "" }

    /// Waits for the banner with Sign In offered (no attempt running).
    @discardableResult
    func waitForSignInOffered(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { signIn.exists && !cancel.exists }
    }

    /// Waits for the banner in its "Signing you back in…" state (Cancel shown).
    @discardableResult
    func waitForAttemptRunning(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { cancel.exists }
    }

    /// Waits for the banner to go away (the account is healthy again).
    @discardableResult
    func waitUntilGone(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { !container.exists && !message.exists }
    }

    /// Waits until the message label contains `text` (e.g. the failure reason).
    @discardableResult
    func waitForMessage(containing text: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        message.waitForText(timeout: timeout) { $0.contains(text) }
    }
}

/// The "Sync problem" banner.
@MainActor
struct SyncFailedBannerPage {
    let app: XCUIApplication

    var container: XCUIElement { app.element(id: AccessibilityID.SyncFailedBanner.container) }
    var message: XCUIElement { app.element(id: AccessibilityID.SyncFailedBanner.message) }
    var retry: XCUIElement { app.element(id: AccessibilityID.SyncFailedBanner.retry) }
}

/// The sidebar's account card: account name, status slot, and its popover
/// (accounts, Add Account…, Settings…).
@MainActor
struct SidebarPage {
    let app: XCUIApplication

    var accountName: XCUIElement { app.element(id: AccessibilityID.Sidebar.accountName) }
    /// The status slot: status text (label), or the container of Sign In again.
    var status: XCUIElement { app.element(id: AccessibilityID.Sidebar.status) }
    /// "Sign in again" — only for a dead session.
    var statusSignIn: XCUIElement { app.element(id: AccessibilityID.Sidebar.statusSignIn) }
    /// The account card's button — opens the account popover.
    var accountCard: XCUIElement { app.element(id: AccessibilityID.Sidebar.accountCard) }
    /// The popover's Add Account… (only while the popover is open). A popover
    /// holds real buttons, not NSMenuItems, so the identifier carries over.
    var addAccountItem: XCUIElement { app.element(id: AccessibilityID.Sidebar.addAccount) }
    var syncFailedBanner: SyncFailedBannerPage { SyncFailedBannerPage(app: app) }

    /// The popover's account rows (only while the popover is open).
    var accountRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.Sidebar.accountRowPrefix)
        )
    }

    /// Whether more than one account is signed in, read WITHOUT opening
    /// anything (it must also hold while a sheet blocks the window): the app
    /// menu's sign-out item names the account only when there is more than
    /// one (`AppEnvironment.signOutMenuTitle`). It replaces the old account
    /// picker, which existed only with two or more accounts.
    var hasSeveralAccounts: Bool { signOutMenuItem(prefix: "Sign Out of ").exists }

    /// Waits for ``hasSeveralAccounts``.
    @discardableResult
    func waitForSeveralAccounts(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { hasSeveralAccounts }
    }

    /// Waits for "Sign in again" to be offered AND clickable (no attempt
    /// running).
    @discardableResult
    func waitForSignInAgainEnabled(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        statusSignIn.waitUntilEnabled(timeout: timeout)
    }

    /// Opens the account popover and picks Add Account….
    func addAccount(file: StaticString = #filePath, line: UInt = #line) {
        accountCard.waitAndClick(file: file, line: line)
        addAccountItem.waitAndClick(file: file, line: line)
    }

    /// Signs the current account out through the app menu's item ("Sign Out"
    /// or "Sign Out of <account>"): the sidebar has no Sign Out any more, and
    /// Settings › Account's Sign Out… asks first. Clicked without opening the
    /// menu ("Herald UI Testing": items are in the tree while closed).
    func signOut(file: StaticString = #filePath, line: UInt = #line) {
        signOutMenuItem(prefix: "Sign Out").waitAndClick(file: file, line: line)
    }

    /// Switches the window to the account whose popover row contains `text`.
    func switchAccount(to text: String, file: StaticString = #filePath, line: UInt = #line) {
        accountCard.waitAndClick(file: file, line: line)
        accountRows.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitAndClick(file: file, line: line)
    }

    /// The menu bar's sign-out item — scoped to the MENU BAR, so an app-wide
    /// title search cannot match something else first.
    private func signOutMenuItem(prefix: String) -> XCUIElement {
        app.menuBars.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
    }
}

/// The conversation list (middle column).
@MainActor
struct MailListPage {
    let app: XCUIApplication

    /// Every row's summary element.
    var rows: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.MailList.rowPrefix)
        )
    }

    /// The row whose VoiceOver summary contains `subject`.
    func row(subject: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                AccessibilityID.MailList.rowPrefix, subject
            )
        ).firstMatch
    }

    /// Waits for a row with this subject.
    @discardableResult
    func waitForRow(subject: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        row(subject: subject).waitForExistence(timeout: timeout)
    }

    /// Waits for rows with ALL of these subjects.
    @discardableResult
    func waitForRows(subjects: [String], timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { subjects.allSatisfy { row(subject: $0).exists } }
    }

    /// The toolbar's New Message button.
    var composeButton: XCUIElement { app.element(id: AccessibilityID.Toolbar.compose) }
    var refreshButton: XCUIElement { app.element(id: AccessibilityID.Toolbar.refresh) }
}

/// The mail window's alerts, found by title.
@MainActor
struct AlertsPage {
    let app: XCUIApplication

    static let signOutFailedTitle = "Couldn’t finish signing out"
    static let actionErrorTitle = "Something went wrong"

    /// The sign-out-failure alert's OK (by identifier, else the alert's OK).
    var signOutFailedOK: XCUIElement {
        let byID = app.element(id: AccessibilityID.Alert.signOutFailedOK)
        return byID.exists ? byID : alert(titled: Self.signOutFailedTitle).buttons["OK"].firstMatch
    }

    /// The sheet (or dialog) that shows this title — macOS presents a
    /// SwiftUI `.alert` as a sheet on the window.
    func alert(titled title: String) -> XCUIElement {
        let showsTitle = NSPredicate(format: "label == %@ OR value == %@", title, title)
        let sheet = app.sheets.containing(showsTitle).firstMatch
        return sheet.exists ? sheet : app.dialogs.containing(showsTitle).firstMatch
    }

    /// Any text in the app whose label contains `text` (an alert's message).
    func text(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// Waits for a static text with the alert's title anywhere in the app —
    /// the most robust presence check across alert presentations.
    @discardableResult
    func waitForAlert(titled title: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        app.staticTexts[title].firstMatch.waitForExistence(timeout: timeout)
    }
}
