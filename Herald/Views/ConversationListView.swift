import HeraldKit
import SwiftUI

/// Middle pane: the conversation rows for the selected scope.
struct ConversationListView: View {
    @Bindable var model: MailViewModel
    /// Search lives here and is debounced before it reaches the view-model, so a
    /// keystroke never re-runs the list's data source (or the detail pane).
    @State private var searchText = ""

    var body: some View {
        List(model.presentedConversations, selection: $model.selectedThreadID) { row in
            ConversationRow(
                row: row,
                toggleStar: { Task { await model.toggleStar(row) } },
                archive: { Task { await model.perform(.archive, onThread: row.id) } },
                trash: { Task { await model.perform(.trash, onThread: row.id) } }
            )
            .tag(row.id)
        }
        .listStyle(.inset)
        // Mail's single-key triage, scoped to this list's focus. As a toolbar or
        // menu shortcut these are window-global and fire while the user is typing
        // in the search field — which is how a bare ⌫ deletes the wrong thing.
        .onKeyPress("e") { act(.archive) }
        .onKeyPress(.delete) { act(.trash) }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search mail")
        .task(id: searchText) {
            guard searchText != model.searchQuery else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            model.searchQuery = searchText
        }
        .overlay {
            if model.presentedConversations.isEmpty {
                ContentUnavailableView(
                    model.searchQuery.isEmpty ? "No Messages" : "No Results",
                    systemImage: MailTheme.symbol(for: model.selection.folder)
                )
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let row = model.presentedConversations.first(where: { $0.id == id }) {
                Button(row.isUnread ? "Mark as Read" : "Mark as Unread") {
                    Task { await model.toggleRead(row) }
                }
                Button(row.isStarred ? "Unstar" : "Star") { Task { await model.toggleStar(row) } }
                Divider()
                Button("Archive") { Task { await model.perform(.archive, onThread: id) } }
                Button("Move to Trash", role: .destructive) {
                    Task { await model.perform(.trash, onThread: id) }
                }
            }
        }
    }

    /// Runs a single-key action against the selection, and passes the key on when
    /// there is nothing selected.
    private func act(_ action: ConversationAction) -> KeyPress.Result {
        guard model.selectedThreadID != nil else { return .ignored }
        Task { await model.performOnSelection(action) }
        return .handled
    }
}

struct ConversationRow: View {
    let row: ConversationSummary
    let toggleStar: () -> Void
    let archive: () -> Void
    let trash: () -> Void

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread is bold text AND a dot: never color alone.
            Circle()
                .fill(row.isUnread ? MailTheme.unreadIndicator : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(participants)
                        .font(.subheadline)
                        .fontWeight(row.isUnread ? .bold : .regular)
                        .lineLimit(1)
                    if row.messageCount > 1 {
                        Text("\(row.messageCount)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(MailTheme.chipBackground, in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(row.latest.displayDate, format: Self.dateFormat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(row.latest.subject.isEmpty ? "(No subject)" : row.latest.subject)
                    .font(.body)
                    .fontWeight(row.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if row.latest.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(row.latest.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            // COMBINE, not the row's old `contain`: as a container VoiceOver
            // stopped on each Text separately and the row's own label — the only
            // place unread/starred/attachments were spoken — was never read.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilitySummary(for: row))
            .accessibilityValue(Text(row.latest.displayDate, format: Self.dateFormat))

            // Its own element on purpose: it is a control, and folding it into the
            // row would cost the only way to star without the mouse.
            Button(action: toggleStar) {
                Image(systemName: row.isStarred ? "star.fill" : "star")
                    .foregroundStyle(row.isStarred ? MailTheme.starred : .secondary)
                    .iconButtonStyle(row.isStarred ? "Unstar" : "Star")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        // The triage verbs, reachable from the VoiceOver rotor rather than only
        // from the menu bar or a right-click.
        .accessibilityAction(named: row.isStarred ? "Unstar" : "Star", toggleStar)
        .accessibilityAction(named: "Archive", archive)
        .accessibilityAction(named: "Move to Trash", trash)
    }

    private var participants: String { Self.participants(for: row) }

    private nonisolated static func participants(for row: ConversationSummary) -> String {
        row.latest.direction == .outbound
            ? "To: " + row.latest.to.joined(separator: ", ")
            : row.latest.fromAddress
    }

    /// What VoiceOver reads for one row. Internal and pure so the states that are
    /// easiest to drop — unread, starred, attachments — are assertable without a
    /// rendered list.
    nonisolated static func accessibilitySummary(for row: ConversationSummary) -> String {
        var parts = [
            participants(for: row),
            row.latest.subject.isEmpty ? "No subject" : row.latest.subject,
        ]
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.isUnread { parts.append("unread") }
        if row.isStarred { parts.append("starred") }
        if row.latest.hasAttachments { parts.append("has attachments") }
        parts.append(row.latest.snippet)
        return parts.joined(separator: ", ")
    }
}
