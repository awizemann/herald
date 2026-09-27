import XCTest

/// The re-auth banner above the mail window.
@MainActor
struct BannerPage {
    let app: XCUIApplication

    var container: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.container) }
    /// Combined text element: label = message (+ the failure reason line).
    var message: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.message) }
    var signIn: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.signIn) }
    /// Present only while an attempt runs.
    var cancel: XCUIElement { app.element(id: AccessibilityID.ReauthBanner.cancel) }

    /// The banner's message label ("" when absent).
    var messageText: String { message.exists ? message.label : "" }

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
        message.waitForLabel(timeout: timeout) { $0.contains(text) }
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

/// The sidebar header: account name, status slot, account options, switcher.
@MainActor
struct SidebarPage {
    let app: XCUIApplication

    var accountName: XCUIElement { app.element(id: AccessibilityID.Sidebar.accountName) }
    /// The status slot: status text (label), or the container of Sign In again.
    var status: XCUIElement { app.element(id: AccessibilityID.Sidebar.status) }
    /// "Sign in again" — only for a dead session.
    var statusSignIn: XCUIElement { app.element(id: AccessibilityID.Sidebar.statusSignIn) }
    var accountOptions: XCUIElement { app.element(id: AccessibilityID.Sidebar.accountOptions) }
    /// Only with more than one account.
    var accountSwitcher: XCUIElement { app.element(id: AccessibilityID.Sidebar.accountSwitcher) }
    var mailboxPicker: XCUIElement { app.element(id: AccessibilityID.Sidebar.mailboxPicker) }
    var syncFailedBanner: SyncFailedBannerPage { SyncFailedBannerPage(app: app) }

    /// Opens the account options menu and picks Add Account….
    func addAccount(file: StaticString = #filePath, line: UInt = #line) {
        accountOptions.waitAndClick(file: file, line: line)
        menuItem(id: AccessibilityID.Sidebar.addAccount, title: "Add Account…")
            .waitAndClick(file: file, line: line)
    }

    /// Opens the account options menu and picks Sign Out (current account).
    func signOut(file: StaticString = #filePath, line: UInt = #line) {
        accountOptions.waitAndClick(file: file, line: line)
        menuItem(id: AccessibilityID.Sidebar.signOut, title: "Sign Out")
            .waitAndClick(file: file, line: line)
    }

    /// Switches the window to the account whose picker row contains `text`.
    func switchAccount(to text: String, file: StaticString = #filePath, line: UInt = #line) {
        accountSwitcher.waitAndClick(file: file, line: line)
        let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", text)).firstMatch
        item.waitAndClick(file: file, line: line)
    }

    /// A SwiftUI `Menu`/`Picker` item: by identifier when SwiftUI carried it
    /// over to the NSMenuItem, else by title.
    private func menuItem(id: String, title: String) -> XCUIElement {
        let byID = app.menuItems.matching(identifier: id).firstMatch
        return byID.waitForExistence(timeout: 2) ? byID : app.menuItems[title].firstMatch
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

    /// Waits for a static text with the alert's title anywhere in the app —
    /// the most robust presence check across alert presentations.
    @discardableResult
    func waitForAlert(titled title: String, timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        app.staticTexts[title].firstMatch.waitForExistence(timeout: timeout)
    }
}
