import HeraldKit
import SwiftUI

/// Accounts header + mailboxes with their folders.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: MailViewModel

    var body: some View {
        List(selection: $model.selection) {
            Section("All Mailboxes") {
                ForEach(MailTheme.sidebarFolders, id: \.self) { folder in
                    FolderRow(
                        scope: MailViewModel.FolderSelection(mailboxID: nil, folder: folder),
                        unread: model.unreadCounts
                    )
                }
            }
            ForEach(model.mailboxes) { mailbox in
                Section(mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName) {
                    ForEach(MailTheme.sidebarFolders, id: \.self) { folder in
                        FolderRow(
                            scope: MailViewModel.FolderSelection(mailboxID: mailbox.id, folder: folder),
                            unread: model.unreadCounts
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { accountHeader }
    }

    private var accountHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.accountLabel)
                    .font(.headline)
                    .lineLimit(1)
                SyncStatusLabel(status: model.status)
            }
            Spacer()
            Menu {
                Button("Add Account…") { environment.presentsAddAccount = true }
                Button("Sign Out", role: .destructive) { Task { await environment.signOut() } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .iconButtonStyle("Account options")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

struct SyncStatusLabel: View {
    let status: MailViewModel.SyncStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .syncing:
            Text("Syncing…").font(.caption).foregroundStyle(MailTheme.syncing)
        case .failed:
            Text("Sync problem").font(.caption).foregroundStyle(MailTheme.failure)
        case .needsReauth:
            Text("Sign in again").font(.caption).foregroundStyle(MailTheme.failure)
        }
    }
}

private struct FolderRow: View {
    let scope: MailViewModel.FolderSelection
    let unread: [MailViewModel.FolderSelection: Int]

    var body: some View {
        let count = unread[scope] ?? 0
        Label(MailTheme.title(for: scope.folder), systemImage: MailTheme.symbol(for: scope.folder))
            .badge(count)
            .tag(scope)
            .accessibilityLabel(
                count > 0
                    ? "\(MailTheme.title(for: scope.folder)), \(count) unread"
                    : MailTheme.title(for: scope.folder)
            )
    }
}
