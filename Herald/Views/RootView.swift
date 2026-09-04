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
        ToolbarItemGroup {
            // No shortcut here: ⌘⇧K belongs to the File menu's "Get New Mail",
            // and two owners of one shortcut is a coin toss over which fires.
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .iconButtonStyle("Refresh")
            }

            // No keyboard shortcuts on these: Mail's muscle-memory `e` lives on
            // the conversation list, where it is scoped to that list's focus. As
            // a toolbar shortcut it was window-global and typing "e" into the
            // search field archived a thread.
            TriageButtons(model: model)
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

    var body: some View {
        // Herald tries the sign-in itself when the app is frontmost (see
        // `AppEnvironment.attemptAutomaticReauthentication`). The banner does not
        // disappear for it — the account IS still signed out — it says what is
        // happening and withdraws the button, which would otherwise open a second
        // authorization window over the one already up.
        let isAutomatic = environment.isReauthenticating(accountID: accountID)
        BannerView(
            systemImage: "lock.fill",
            tint: MailTheme.failure,
            text: isAutomatic
                ? "Your session expired. Signing you back in…"
                : "Your session expired. Sign in again to keep syncing."
        ) {
            if isAutomatic {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Button("Sign In") { Task { await environment.reauthenticate(accountID: accountID) } }
            }
        }
    }
}

struct BannerView<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout)
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
