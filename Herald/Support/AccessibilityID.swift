import Foundation

/// Accessibility IDENTIFIERS — the stable handles the UI tests (`HeraldUITests`)
/// find controls by. Identifiers only: they are never spoken, so they change
/// nothing a VoiceOver or Voice Control user meets (labels, hints and values
/// stay where they are, in the views).
///
/// This one file is compiled into BOTH the app and the UI-test bundle (see
/// `project.yml`) — a UI-test bundle cannot import the app module, and two
/// copies of these strings would drift. So: Foundation only, no app types.
///
/// Scheme: `<surface>.<part>[.<control>]`, lowerCamel segments —
/// `banner.reauth.signIn`, `compose.error.signIn`, `sidebar.status.signIn`.
/// The `uitest.` prefix is reserved for the Debug-only harness controls
/// (`Herald/UITestSupport/UITestControls.swift`).
nonisolated enum AccessibilityID {
    /// The re-auth banner above the mail window (`ReauthBanner`).
    enum ReauthBanner {
        /// The banner as a whole (a container).
        static let container = "banner.reauth"
        /// The banner's text: ONE combined element, so its label is the
        /// message AND, after a failed attempt, the reason line under it
        /// ("The last sign-in didn’t work: …").
        static let message = "banner.reauth.message"
        static let signIn = "banner.reauth.signIn"
        /// Shown instead of Sign In while an attempt runs — its presence is
        /// how a test sees the attempt (the spinner beside it is hidden from
        /// accessibility, so it has no identifier to find).
        static let cancel = "banner.reauth.cancel"
    }

    /// The "Sync problem" banner (`MailWindow.statusBanner`, `.failed`).
    enum SyncFailedBanner {
        static let container = "banner.syncFailed"
        static let message = "banner.syncFailed.message"
        static let retry = "banner.syncFailed.retry"
    }

    enum Sidebar {
        /// The status slot under the account name (`SyncStatusLabel`): the
        /// status text, or — for a dead session — the container of the
        /// "Sign in again" button.
        static let status = "sidebar.status"
        /// The slot's "Sign in again" button (dead session only).
        static let statusSignIn = "sidebar.status.signIn"
        static let accountName = "sidebar.accountName"
        /// The account card's button — opens the account popover (it replaced
        /// the old account options menu and account picker; Sign Out moved to
        /// Settings › Account, `Settings.signOut`).
        static let accountCard = "sidebar.accountCard"
        /// The popover's rows: `accountRowPrefix + <accountID>`.
        static let accountRowPrefix = "sidebar.accountCard.account."
        /// The popover's Add Account… (re-homed from the old options menu).
        static let addAccount = "sidebar.accountCard.addAccount"
        /// The popover's Settings… (opens Settings › Account).
        static let settings = "sidebar.accountCard.settings"
        /// The source list of the level on screen.
        static let list = "sidebar.list"
        /// "‹ Domains" / "‹ {domain}".
        static let back = "sidebar.back"
        /// Level 2's gear (Domain Settings…).
        static let domainSettings = "sidebar.domainSettings"
        /// The level's filter field (domains past 8, mailboxes always).
        static let filter = "sidebar.filter"
        /// Rows: `rowPrefix + allDomains | domain.<id> | label.<id> |
        /// allMailboxes | mailbox.<id> | folder.<name>`.
        static let rowPrefix = "sidebar.row."
    }

    /// The Settings window (`SettingsView` and its pages).
    enum Settings {
        static let sidebar = "settings.sidebar"
        /// The account card's switcher menu.
        static let accountCard = "settings.accountCard"
        /// Each sidebar item is `itemPrefix + <route key>` — `general`,
        /// `notifications`, `privacy`, `account`, `signatures`,
        /// `domain.<domainID>` at the root, and `page.<page>` (`overview`,
        /// `mailboxes`, `signatures`, `remove`) inside a domain.
        static let itemPrefix = "settings.item."
        /// "‹ Settings" at the top of a domain's level.
        static let back = "settings.back"
        /// The detail pane's serif title.
        static let pageTitle = "settings.pageTitle"
        static let density = "settings.general.density"
        static let syncNow = "settings.account.syncNow"
        /// Each colour swatch is `tintSwatchPrefix + <token name>`.
        static let tintSwatchPrefix = "settings.account.tint."
        static let tintReset = "settings.account.tintReset"
        /// Sign Out… — re-homed here from `Sidebar.signOut` (handoff §4).
        static let signOut = "settings.account.signOut"
    }

    /// The conversation list (middle column).
    enum MailList {
        static let list = "mailList"
        /// Each row's summary element is `rowPrefix + threadID`; its label is
        /// the row's VoiceOver summary (sender, subject, …, snippet), so a test
        /// finds a subject with `identifier BEGINSWITH rowPrefix AND label
        /// CONTAINS "<subject>"`.
        static let rowPrefix = "mailList.row."
    }

    enum Toolbar {
        static let compose = "toolbar.compose"
        static let refresh = "toolbar.refresh"
    }

    /// A compose window (`ComposeView`).
    enum Compose {
        static let to = "compose.to"
        static let cc = "compose.cc"
        static let bcc = "compose.bcc"
        static let subject = "compose.subject"
        static let body = "compose.body"
        static let send = "compose.send"
        static let attach = "compose.attach"
        static let deleteDraft = "compose.deleteDraft"
        /// The header spinner while the composer is busy (saving/sending).
        static let busy = "compose.busy"
        /// The error bar's text: ONE combined element (message plus, when
        /// offered, the last sign-in's failure reason). The bar has no
        /// container element of its own — this element's presence IS the bar.
        static let errorMessage = "compose.error.message"
        /// The bar's Sign In (dead session only).
        static let errorSignIn = "compose.error.signIn"
        /// "Signing in…", in Sign In's place while the attempt runs.
        static let errorSigningIn = "compose.error.signingIn"
    }

    /// The first-run screen and the Add Account sheet (`OnboardingView`).
    enum Onboarding {
        static let origin = "onboarding.origin"
        /// Sign In (label "Signing in" while one runs).
        static let signIn = "onboarding.signIn"
        /// Cancel: the sheet's dismiss, or — while signing in — cancel the sign-in.
        static let cancel = "onboarding.cancel"
        static let error = "onboarding.error"
        /// The combined "Signing in. <stage>" line.
        static let progress = "onboarding.progress"
    }

    /// Buttons of the mail window's alerts. The alerts themselves are found by
    /// title ("Couldn’t finish signing out", "Something went wrong").
    enum Alert {
        static let signOutFailedOK = "alert.signOutFailed.ok"
        static let actionErrorOK = "alert.actionError.ok"
    }
}
