import HeraldKit
import SwiftUI

/// Middle pane: the conversation rows for the selected scope.
struct ConversationListView: View {
    @Bindable var model: MailViewModel
    /// Search lives here and is debounced before it reaches the view-model, so a
    /// keystroke never re-runs the list's data source (or the detail pane).
    @State private var searchText = ""

    var body: some View {
        List(model.conversations, selection: $model.selectedThreadID) { row in
            ConversationRow(row: row) {
                Task { await model.toggleStar(row) }
            }
            .tag(row.id)
        }
        .listStyle(.inset)
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
            if model.conversations.isEmpty {
                ContentUnavailableView(
                    model.searchQuery.isEmpty ? "No Messages" : "No Results",
                    systemImage: MailTheme.symbol(for: model.selection.folder)
                )
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = model.conversations.first(where: { $0.id == id }) {
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
}

struct ConversationRow: View {
    let row: ConversationSummary
    let toggleStar: () -> Void

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
                            .background(.quaternary, in: Capsule())
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
                            .accessibilityLabel("Has attachments")
                    }
                    Text(row.latest.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Button(action: toggleStar) {
                Image(systemName: row.isStarred ? "star.fill" : "star")
                    .foregroundStyle(row.isStarred ? MailTheme.starred : .secondary)
                    .iconButtonStyle(row.isStarred ? "Unstar" : "Star")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var participants: String {
        row.latest.direction == .outbound
            ? "To: " + row.latest.to.joined(separator: ", ")
            : row.latest.fromAddress
    }

    private var accessibilitySummary: String {
        var parts = [participants, row.latest.subject.isEmpty ? "No subject" : row.latest.subject]
        if row.isUnread { parts.append("unread") }
        if row.isStarred { parts.append("starred") }
        if row.latest.hasAttachments { parts.append("has attachments") }
        return parts.joined(separator: ", ")
    }
}
