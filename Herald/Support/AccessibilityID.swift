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
        /// The account options menu (Add Account…, Sign Out).
        static let accountOptions = "sidebar.accountOptions"
        static let addAccount = "sidebar.accountOptions.addAccount"
        static let signOut = "sidebar.accountOptions.signOut"
        /// The account picker; only there with more than one account.
        static let accountSwitcher = "sidebar.accountSwitcher"
        static let mailboxPicker = "sidebar.mailboxPicker"
    }

    /// The conversation list (middle column).
    enum MailList {
        static let list = "mailList"
        /// Each row's summary element is `rowPrefix + threadID`; its label is
        /// the row's VoiceOver summary (sender, subject, …, snippet), so a test
        /// finds a subject with `identifier BEGINSWITH rowPrefix AND label
        /// CONTAINS "<subject>"`.
        static let rowPrefix = "mailList.row."
        /// The header's folder menu (All domains and domain scopes only).
        static let folderMenu = "mailList.folderMenu"
        /// The header's plain title (mailbox scope, where it is not a menu).
        static let title = "mailList.title"
        /// The "{scope} · {folder}" caption under the title.
        static let caption = "mailList.caption"
        /// The open label chip's × (clears the label filter).
        static let clearLabel = "mailList.clearLabel"
        /// An empty list's title text.
        static let emptyTitle = "mailList.empty.title"
        /// The Drafts-in-a-mailbox empty state's "Show All Drafts".
        static let showAllDrafts = "mailList.empty.showAllDrafts"
        /// Each draft row's summary element: `draftRowPrefix + draftID`.
        static let draftRowPrefix = "mailList.draft."
        /// The drilled-in thread's "‹ {folder}" back link.
        static let threadBack = "mailList.thread.back"
        /// The drilled-in thread's subject heading.
        static let threadSubject = "mailList.thread.subject"
        /// Each thread message row's summary element: `messageRowPrefix + messageID`.
        static let messageRowPrefix = "mailList.message."
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
