import HeraldKit
import SwiftUI

/// Switches between the launch placeholder, onboarding and the mail UI.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

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
        .task { await environment.start() }
        .onChange(of: scenePhase) { _, phase in
            Task { await environment.setWindowActive(phase == .active) }
        }
    }
}

/// Shown only while a real milestone is outstanding — no artificial delay.
struct LaunchPlaceholder: View {
    let milestone: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 40, weight: .light))
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
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 240
    @AppStorage("listWidth") private var listWidth: Double = 340

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: sidebarWidth, max: 360)
        } content: {
            ConversationListView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: listWidth, max: 520)
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
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .iconButtonStyle("Refresh")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button { Task { await model.performOnSelection(.archive) } } label: {
                Image(systemName: "archivebox")
                    .iconButtonStyle("Archive")
            }
            // Mail's muscle-memory single-key archive, next to the ⌘⇧A menu item.
            .keyboardShortcut("e", modifiers: [])
            .disabled(model.selectedThreadID == nil)

            Button { Task { await model.performOnSelection(.trash) } } label: {
                Image(systemName: "trash")
                    .iconButtonStyle("Move to Trash")
            }
            .disabled(model.selectedThreadID == nil)
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
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
