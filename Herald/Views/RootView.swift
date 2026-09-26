import HeraldKit
import SwiftUI

/// Switches between the launch placeholder, onboarding and the mail UI.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.phase {
            case .openingCache:
                LaunchPlaceholder(milestone: "Opening your mail cache…")
            case .restoringAccount:
                LaunchPlaceholder(milestone: "Restoring your account…")
            case .signedOut:
                OnboardingView()
            case .ready:
                if let mail = environment.mail {
                    MailWindow(model: mail)
                } else {
                    LaunchPlaceholder(milestone: "Preparing your mailboxes…")
                }
            case .failed(let message):
                LaunchFailure(message: message)
            }
        }
        .frame(minWidth: MailTheme.minWindow.width, minHeight: MailTheme.minWindow.height)
        // Sync cadence is driven by the APPLICATION's activation inside
        // `AppEnvironment`, not by this scene's phase: a compose window taking
        // key made the mail scene inactive and backed the poll off to idle.
        .task { await environment.start() }
    }
}

/// Shown only while a real milestone is outstanding — no artificial delay.
struct LaunchPlaceholder: View {
    let milestone: String

    var body: some View {
        VStack(spacing: MailTheme.Spacing.md) {
            Image(systemName: "envelope")
                .font(MailTheme.Typography.largeGlyph)
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
            Text(milestone)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Herald is starting. \(milestone)")
    }
}

struct LaunchFailure: View {
    @Environment(AppEnvironment.self) private var environment
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Herald could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await environment.start() } }
        }
    }
}

/// The three-pane mail UI.
struct MailWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: MailViewModel
    /// Ideal column widths. Plain constants: the `@AppStorage` keys they replace
    /// were never written by anything, so they persisted nothing and only made
    /// the split view look restorable.
    private static let sidebarWidth: Double = 240
    private static let listWidth: Double = 340

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: Self.sidebarWidth, max: 360)
        } content: {
            // The only view state in this window that belongs to ONE account is
            // the list's debounced search text, so the reset is scoped to the
            // list. Re-iding the whole split view would also throw away the
            // user's column widths on every account switch.
            MiddleColumnView(model: model)
                .id(model.accountID)
                .navigationSplitViewColumnWidth(min: 280, ideal: Self.listWidth, max: 520)
        } detail: {
            ReadingPaneView(model: model)
        }
        .navigationTitle(model.accountLabel)
        .navigationSubtitle(model.scopeTitle)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: Bindable(environment).presentsAddAccount) { OnboardingView(isSheet: true) }
        .focusedSceneValue(\.mailModel, model)
        // Primitive mirrors of the selection: the menu bar's enablement and its
        // Star/Mark-as-Read titles have to change when the selection does, and a
        // focused reference type never reports that it changed. See MailCommands.
        .focusedSceneValue(\.selectedThreadID, model.selectedThreadID)
        // The Message menu's Archive title and its Trash enablement depend on the
        // scope, and a focused reference type never reports that it changed.
        .focusedSceneValue(\.selectionFolder, model.selection.folder)
        .focusedSceneValue(\.selectedMessageID, model.selectedMessageID)
        .focusedSceneValue(\.selectedIsUnread, model.selectedConversation?.isUnread)
        .focusedSceneValue(\.selectedIsStarred, model.selectedConversation?.isStarred)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // One ACTION stack — Compose, Archive, Trash — and Refresh on its own
        // beside the search field (owner's layout call, 2026-09-20). Compose sits
        // with the triage buttons rather than in the leading `.navigation` slot
        // over the list, so every button that does something to mail is in one
        // place and the two "housekeeping" controls (Refresh, Search) sit apart.
        //
        // No keyboard shortcut on Compose: ⌘N belongs to the File menu's
        // "New Message", and two owners of one shortcut is the bug #10 fixed.
        ToolbarItemGroup {
            Button { model.requestCompose(.new) } label: {
                Image(systemName: "square.and.pencil")
                    .iconButtonStyle("New Message")
            }

            // No keyboard shortcuts on these: Mail's muscle-memory `e` lives on
            // the conversation list, where it is scoped to that list's focus. As
            // a toolbar shortcut it was window-global and typing "e" into the
            // search field archived a thread.
            TriageButtons(model: model)
        }

        // Its own item, so it renders as a separate group between the action
        // stack and the search field. No shortcut here: ⌘⇧K belongs to the File
        // menu's "Get New Mail".
        ToolbarItem {
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .iconButtonStyle("Refresh")
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.status {
        case .needsReauth:
            // Scoped to THIS account: another account's session is untouched.
            ReauthBanner(accountID: model.accountID)
        case .failed(let message):
            BannerView(
                systemImage: "exclamationmark.triangle.fill",
                tint: MailTheme.failure,
                text: "Sync problem: \(message)"
            ) {
                Button("Retry") { Task { await model.refresh() } }
            }
        case .idle, .syncing:
            EmptyView()
        }
    }
}

struct ReauthBanner: View {
    @Environment(AppEnvironment.self) private var environment
    let accountID: Account.ID
    /// The account whose attempt the user's Cancel stopped. Set by the Cancel
    /// button, consumed by the state change it causes, so that change is
    /// announced as a cancel rather than as a fresh expiry. Keyed to the
    /// ACCOUNT, and dropped when the banner switches accounts: this view's
    /// state survives an account switch, and a flag left over from account A
    /// must never turn account B's attempt ending into "Sign-in cancelled".
    @State private var cancelledAccountID: Account.ID?

    var body: some View {
        // Herald tries the sign-in itself when the app is frontmost (see
        // `AppEnvironment.attemptAutomaticReauthentication`). The banner does not
        // disappear for it — the account IS still signed out — it says what is
        // happening and swaps Sign In for Cancel: a second Sign In would open a
        // second authorization window over the one already up.
        let isReauthenticating = environment.isReauthenticating(accountID: accountID)
        // Only while no attempt is running: an attempt clears it as it starts,
        // and this keeps a stale line from sitting under "Signing you back in…".
        let failureReason = isReauthenticating ? nil : environment.reauthError(accountID: accountID)
        BannerView(
            systemImage: "lock.fill",
            tint: MailTheme.failure,
            text: Self.message(isReauthenticating: isReauthenticating),
            detail: failureReason.map(Self.failureDetail)
        ) {
            if isReauthenticating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                // For EVERY attempt, the automatic one included. Either kind can
                // stall in the browser hand-off (issue #9; the 2026-09-26
                // incident was an automatic one), and without this the spinner
                // is the end of the road until the 10-minute watchdog. Cancel
                // gives the Sign In button back at once; an automatic attempt
                // then waits out its cooldown before trying by itself again.
                Button("Cancel") {
                    cancelledAccountID = accountID
                    environment.cancelReauthentication(accountID: accountID)
                }
                .accessibilityLabel("Cancel sign-in")
                .accessibilityHint("Stops signing in. The Sign In button comes back.")
            } else {
                Button("Sign In") { Task { await environment.reauthenticate(accountID: accountID) } }
            }
        }
        // The banner appears BELOW the toolbar without taking focus, and an
        // attempt then swaps the text and the button underneath a VoiceOver
        // cursor that may be sitting on it. Every state change is announced, so
        // it is heard rather than discovered: same
        // `AccessibilityNotification.Announcement` pattern as the compose window.
        //
        // Announce only — no forced focus move: yanking the cursor out of the
        // list to a banner the user did not ask for is worse than the swapped
        // button, and the announcement names the control that replaced it.
        .onAppear { announce(Self.announcement(isReauthenticating: isReauthenticating)) }
        .onChange(of: isReauthenticating) { _, reauthenticating in
            announce(Self.stateChangeAnnouncement(
                isReauthenticating: reauthenticating,
                cancelledAccountID: cancelledAccountID,
                accountID: accountID,
                // Read fresh: the attempt records its reason before it releases
                // the account, so the reason is already there when this fires.
                failureReason: environment.reauthError(accountID: accountID)
            ))
            cancelledAccountID = nil
        }
        .onChange(of: accountID) { _, _ in cancelledAccountID = nil }
    }

    /// What a change of the attempt state announces. The cancel wording only
    /// for the account whose Cancel the user pressed — pure and static so the
    /// cross-account rule is assertable without a rendered banner.
    ///
    /// An attempt that ended in failure says why, once, here — the banner's
    /// secondary line shows the same reason to sighted users (audit W5).
    nonisolated static func stateChangeAnnouncement(
        isReauthenticating: Bool,
        cancelledAccountID: Account.ID?,
        accountID: Account.ID,
        failureReason: String? = nil
    ) -> String {
        if !isReauthenticating, cancelledAccountID == accountID { return cancelledAnnouncement }
        if !isReauthenticating, let failureReason { return failureAnnouncement(failureReason) }
        return announcement(isReauthenticating: isReauthenticating)
    }

    /// The banner's secondary line after a failed attempt.
    nonisolated static func failureDetail(_ reason: String) -> String {
        "The last sign-in didn’t work: \(reason)"
    }

    /// What VoiceOver hears when an attempt ends in failure: the reason, and
    /// where the way back in is.
    nonisolated static func failureAnnouncement(_ reason: String) -> String {
        "Sign-in didn’t work: \(reason) Use the Sign In button in the banner to try again."
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// The banner's own text. Pure and static so it is assertable without a
    /// rendered banner.
    nonisolated static func message(isReauthenticating: Bool) -> String {
        isReauthenticating
            ? "Your session expired. Signing you back in…"
            : "Your session expired. Sign in again to keep syncing."
    }

    /// What VoiceOver hears. Each state names the control the sighted user can
    /// see, because the announcement is all the cursor gets.
    nonisolated static func announcement(isReauthenticating: Bool) -> String {
        isReauthenticating
            ? "Your session expired. Signing you back in… Use the Cancel button in the banner to stop."
            : "Your session expired. Use the Sign In button in the banner to keep syncing."
    }

    /// What VoiceOver hears when the user's own Cancel stopped an attempt:
    /// that it worked, and where the way back in is now.
    nonisolated static let cancelledAnnouncement =
        "Sign-in cancelled. Use the Sign In button in the banner when you're ready."
}

struct BannerView<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    /// An optional secondary line under ``text`` (the re-auth banner's reason
    /// the last attempt failed). Read together with the text as one element.
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            // Decorative: the banner's text says everything the glyph does, and
            // as a visible element it made VoiceOver read the symbol's name
            // ("lock", "exclamationmark triangle") ahead of the sentence.
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                Text(text).font(.callout)
                if let detail {
                    // Server-supplied wording can run long: two lines here,
                    // the whole of it in the tooltip and for VoiceOver.
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(detail)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            actions
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
