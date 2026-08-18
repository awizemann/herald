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
            MiddleColumnView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: Self.listWidth, max: 520)
        } detail: {
            ReadingPaneView(model: model)
        }
        .navigationTitle(model.accountLabel)
        .navigationSubtitle(MailTheme.title(for: model.selection.folder))
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

            Button { Task { await model.performOnSelection(.archive) } } label: {
                Image(systemName: "archivebox")
                    .iconButtonStyle(model.archiveActionTitle)
            }
            // Mail's muscle-memory `e` lives on the conversation list, where it
            // is scoped to that list's focus: as a toolbar shortcut it was
            // window-global and typing "e" into the search field archived a thread.
            .disabled(model.selectedThreadID == nil)

            // Nothing to trash in the Trash — the button goes, rather than
            // sitting there doing nothing (issue #8).
            if model.offersTrashAction {
                Button { Task { await model.performOnSelection(.trash) } } label: {
                    Image(systemName: "trash")
                        .iconButtonStyle("Move to Trash")
                }
                .disabled(model.selectedThreadID == nil)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.status {
        case .needsReauth:
            ReauthBanner()
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

    var body: some View {
        BannerView(
            systemImage: "lock.fill",
            tint: MailTheme.failure,
            text: "Your session expired. Sign in again to keep syncing."
        ) {
            Button("Sign In") { Task { await environment.reauthenticate() } }
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
