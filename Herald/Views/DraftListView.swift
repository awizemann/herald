import HeraldKit
import SwiftUI

/// The Drafts folder's middle column.
///
/// Deliberately the same shape as ``ConversationListView`` — same `List` style,
/// same unmeasured-row height floor, same row anatomy and density — because it
/// sits in the same slot and switching folders must not feel like switching
/// apps. What it is NOT is a conversation list: drafts are not messages, have
/// no read/unread state, no star and no thread to drill into, so none of those
/// affordances appear.
struct DraftListView: View {
    @Bindable var model: MailViewModel
    /// The same field the conversation list searches with (owned by
    /// ``MiddleColumnView``); here it narrows the drafts locally.
    @Binding var searchText: String
    let metrics: ListColumn.RowMetrics

    var body: some View {
        // Once per pass, not per row (see `ConversationListView`).
        let attribution = model.rowAttributionIndex()
        let accountTint = model.listAccountTint
        let rowHeight = metrics.conversationRowHeight(.current)
        List(model.presentedDrafts, selection: $model.selectedDraftID) { draft in
            DraftRow(
                draft: draft,
                // Same rule as a conversation row (handoff §2); at All domains a
                // draft tied to no mailbox gets the "No mailbox" tag instead.
                attribution: attribution.attribution(forMailbox: draft.mailboxID),
                accountTint: accountTint,
                metrics: metrics,
                minHeight: rowHeight,
                isSelected: model.selectedDraftID == draft.id,
                open: { model.openDraft(draft.id) },
                delete: { Task { await model.deleteDraft(draft.id) } }
            )
            .tag(draft.id)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // Same NSTableView row-height floor as the conversation list: a freshly
        // inserted row it has not measured is otherwise drawn at 24pt.
        .environment(\.defaultMinListRowHeight, rowHeight)
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
            if model.presentedDrafts.isEmpty {
                // Inside a mailbox: "No drafts in team@" + Show All Drafts,
                // since mailbox-less drafts only list under All domains.
                ListEmptyStateView(state: model.listEmptyState) { model.showAllDrafts() }
            }
        }
        .listSearchField(model: model, text: $searchText)
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

/// One draft row: attribution + "Draft" (in `danger`), the subject, how it
/// starts, when it was last touched (handoff §3.1 "Drafts", screenshot 5a-3).
struct DraftRow: View {
    let draft: DraftSummary
    let attribution: ListColumn.Attribution
    let accountTint: MailTheme.AccountTint?
    let metrics: ListColumn.RowMetrics
    let minHeight: CGFloat
    var isSelected = false
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ListColumn.Layout.rowColumnGap) {
            // Where a conversation row carries its unread dot. Blank, not absent:
            // the two lists' text columns start at the same x or switching
            // folders visibly shifts every row sideways.
            UnreadDot(isUnread: false)

            VStack(alignment: .leading, spacing: ListColumn.Layout.lineGap) {
                HStack(spacing: ListColumn.Layout.attributionGap) {
                    if !attribution.isEmpty {
                        RowAttributionView(attribution: attribution, tint: accountTint, isSelected: isSelected)
                    }
                    // `danger` names what the row IS; on a selected row it
                    // yields to the selection's own text colour, since a fixed
                    // red on the accent fill would not read.
                    Text(Self.senderTitle)
                        .textStyle(MailTheme.Typography.bodyMedium)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(MailTheme.Color.danger))
                        .lineLimit(1)
                    if metrics.subjectInline {
                        Text(MailViewModel.subjectLabel(for: draft))
                            .textStyle(MailTheme.Typography.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ListColumn.Layout.badgeRowHeight)
                if !metrics.subjectInline {
                    Text(MailViewModel.subjectLabel(for: draft))
                        .textStyle(MailTheme.Typography.body)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: MailTheme.Spacing.xs) {
                    if draft.hasAttachments {
                        Image(systemName: MailTheme.Symbol.attachment)
                            .font(MailTheme.Typography.inlineGlyph)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(draft.snippet)
                        .textStyle(MailTheme.Typography.snippet)
                        .foregroundStyle(.secondary)
                        .lineLimit(metrics.snippetLines)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(MailViewModel.accessibilitySummary(for: draft, attribution: attribution.spoken))
            .accessibilityValue(RowDateFormatter.full(draft.updatedAt))
            .accessibilityIdentifier(AccessibilityID.MailList.draftRowPrefix + draft.id)

            // The date on top, the open affordance beneath it — where a
            // conversation row has its star.
            VStack(alignment: .trailing, spacing: 0) {
                RowDateLabel(date: draft.updatedAt)
                Button(action: open) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.tertiary)
                        .iconButtonStyle("Open Draft")
                }
                .buttonStyle(.plain)
            }
            .fixedSize()
        }
        .padding(.vertical, metrics.verticalPadding)
        .padding(.horizontal, ListColumn.Layout.rowHorizontalPadding)
        .frame(minHeight: minHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .selectionOutline(isSelected)
        // A count-2 tap, not the count-1 gesture that raced List's own selection
        // in issue #4: a double click still lets the first click through to the
        // list, so the row selects and then opens.
        .onTapGesture(count: 2, perform: open)
        // The same two verbs from the VoiceOver rotor, where neither the
        // double-click nor the trailing button is reachable.
        .accessibilityAction(named: "Open Draft", open)
        .accessibilityAction(named: "Delete Draft", delete)
    }

    /// Where a conversation row names its sender, a draft says what it is.
    static let senderTitle = "Draft"
}
