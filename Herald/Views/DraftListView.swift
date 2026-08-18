import HeraldKit
import SwiftUI

/// The Drafts folder's middle column.
///
/// Deliberately the same shape as ``ConversationListView`` — same `List` style,
/// same unmeasured-row height floor, same trailing date slot, same row metrics —
/// because it sits in the same slot and switching folders must not feel like
/// switching apps. What it is NOT is a conversation list: drafts are not
/// messages, have no read/unread state, no star and no thread to drill into, so
/// none of those affordances appear.
struct DraftListView: View {
    @Bindable var model: MailViewModel

    var body: some View {
        List(model.drafts, selection: $model.selectedDraftID) { draft in
            DraftRow(
                draft: draft,
                // Same rule as a conversation row: attribute the mailbox only
                // where the scope leaves it ambiguous.
                mailboxName: model.selection.mailboxID == nil
                    ? model.mailboxName(for: draft.mailboxID)
                    : nil,
                mailboxTint: model.selection.mailboxID == nil
                    ? model.mailboxTint(for: draft.mailboxID)
                    : nil,
                open: { model.openDraft(draft.id) },
                delete: { Task { await model.deleteDraft(draft.id) } }
            )
            .tag(draft.id)
        }
        .listStyle(.inset)
        // Same NSTableView row-height floor as the conversation list: a freshly
        // inserted row it has not measured is otherwise drawn at 24pt.
        .environment(\.defaultMinListRowHeight, MailTheme.rowMinHeight)
        // ⏎ opens, ⌫ deletes — scoped to this list's focus, exactly like the
        // conversation list's triage keys, so neither fires while the user is
        // typing somewhere else in the window.
        .onKeyPress(.return) {
            guard model.selectedDraftID != nil else { return .ignored }
            model.openSelectedDraft()
            return .handled
        }
        .onKeyPress(.delete) {
            guard model.selectedDraftID != nil else { return .ignored }
            Task { await model.deleteSelectedDraft() }
            return .handled
        }
        .overlay {
            if model.drafts.isEmpty {
                ContentUnavailableView(
                    "No Drafts",
                    systemImage: MailTheme.draftsSymbol,
                    description: Text("Messages you start but don't send appear here.")
                )
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open Draft") { model.openDraft(id) }
                Divider()
                Button("Delete Draft", role: .destructive) {
                    Task { await model.deleteDraft(id) }
                }
            }
        }
    }
}

/// One draft row: who it is for, what it is about, how it starts, when it was
/// last touched.
struct DraftRow: View {
    let draft: DraftSummary
    let mailboxName: String?
    let mailboxTint: MailboxTint?
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
            // Where a conversation row carries its unread dot. Blank, not absent:
            // the two lists' text columns start at the same x or switching
            // folders visibly shifts every row sideways.
            Color.clear
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                HStack(spacing: MailTheme.Spacing.sm) {
                    if let mailboxName {
                        MailboxChip(name: mailboxName, tint: mailboxTint)
                            .layoutPriority(2)
                    } else {
                        recipientsLabel
                    }
                    Spacer(minLength: 0)
                }
                if mailboxName != nil { recipientsLabel }
                Text(MailViewModel.subjectLabel(for: draft))
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: MailTheme.Spacing.xs) {
                    if draft.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(draft.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(MailViewModel.accessibilitySummary(for: draft))
            .accessibilityValue(RowDateFormatter.full(draft.updatedAt))

            // Same fixed trailing slot as a conversation row, so the two lists
            // line up: the date on top, the open affordance beneath it.
            VStack(alignment: .trailing, spacing: 0) {
                RowDateLabel(date: draft.updatedAt)
                Button(action: open) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.secondary)
                        .iconButtonStyle("Open Draft")
                }
                .buttonStyle(.plain)
            }
            .frame(width: MailTheme.dateSlotWidth, alignment: .trailing)
        }
        .frame(minHeight: MailTheme.rowMinHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, MailTheme.Spacing.xxs)
        // A count-2 tap, not the count-1 gesture that raced List's own selection
        // in issue #4: a double click still lets the first click through to the
        // list, so the row selects and then opens.
        .onTapGesture(count: 2, perform: open)
        // The same two verbs from the VoiceOver rotor, where neither the
        // double-click nor the trailing button is reachable.
        .accessibilityAction(named: "Open Draft", open)
        .accessibilityAction(named: "Delete Draft", delete)
    }

    private var recipientsLabel: some View {
        Text(MailViewModel.recipientsLabel(for: draft))
            .font(.subheadline)
            .foregroundStyle(draft.recipients.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(2)
    }
}
