import HeraldKit
import SwiftUI

/// The middle column. It is either the conversation list for the current scope
/// or, once the user explicitly opens a multi-message conversation, that
/// thread's messages. Selecting a row only previews it in the reading pane.
///
/// The swap is a VM flag (`isShowingThread`), never a `NavigationStack` push:
/// both lists stay lazy, neither is `.id()`-reset, and coming back lands on the
/// same row with the same selection.
struct MiddleColumnView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MailViewModel
    /// The search field's text lives HERE, not in ``ConversationListView``.
    ///
    /// That view is torn out of the hierarchy whenever the user drills into a
    /// thread, and `@State` dies with it: on the way back the field came up
    /// empty, its debounce saw "" ≠ the committed query and wiped the search
    /// (server results and all) 250 ms after the user pressed ⎋. Owned by the
    /// view that SURVIVES the swap, it simply comes back as it was.
    @State private var searchText = ""
    /// Settings › General's density, observed live: a change there re-lays
    /// every row at once. Read through ``ListDensity/resolve(_:)`` so an absent
    /// or unknown value is Comfortable, the same rule as the Settings page.
    @AppStorage(ListDensity.storageKey) private var densityRaw = ListDensity.comfortable.rawValue

    private var metrics: ListColumn.RowMetrics { ListColumn.RowMetrics(ListDensity.resolve(densityRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            // The thread view brings its own header (back link, subject).
            if !model.isShowingThread {
                ListHeaderBand(model: model)
                    .transition(.opacity)
            }
            ZStack {
                if model.isShowingDrafts {
                    // Drafts are not conversations and not messages — a different
                    // list entirely, in the same slot.
                    DraftListView(model: model, searchText: $searchText, metrics: metrics)
                        .transition(.opacity)
                } else if model.isShowingThread {
                    ThreadMessageListView(model: model, metrics: metrics)
                        .transition(.opacity)
                } else {
                    ConversationListView(model: model, searchText: $searchText, metrics: metrics)
                        .transition(.opacity)
                }
            }
        }
        .background(MailTheme.Color.bg)
        // A cross-fade, and none at all when the user asked for less motion.
        .animation(reduceMotion ? nil : MailTheme.Animation.quick, value: model.isShowingThread)
        .animation(reduceMotion ? nil : MailTheme.Animation.quick, value: model.isShowingDrafts)
    }
}

/// The conversation rows for the selected scope.
struct ConversationListView: View {
    @Bindable var model: MailViewModel
    /// Search text, owned by ``MiddleColumnView`` so it survives a drill-in, and
    /// debounced here before it reaches the view-model — so a keystroke never
    /// re-runs the list's data source (or the detail pane).
    @Binding var searchText: String
    let metrics: ListColumn.RowMetrics

    var body: some View {
        // Once per pass, not per row: every row of the pass shares the scope's
        // attribution rule, the domain monograms and the account tint.
        let attribution = model.rowAttributionIndex()
        let accountTint = model.listAccountTint
        let rowHeight = metrics.conversationRowHeight(.current)
        List(selection: $model.selectedThreadID) {
            ForEach(model.presentedConversations) { row in
                ConversationRow(
                    row: row,
                    // The COMMITTED query, not the field's text: the rows on screen
                    // were filtered with this one, so marking them with a needle the
                    // user is still typing would highlight what is not matched yet.
                    highlight: model.searchQuery,
                    // Only the levels the scope has not fixed (handoff §2).
                    attribution: attribution.attribution(forMailbox: row.latest.mailboxID),
                    accountTint: accountTint,
                    metrics: metrics,
                    minHeight: rowHeight,
                    isSelected: model.selectedThreadID == row.id,
                    labels: model.labels(forThread: row.id),
                    toggleStar: { Task { await model.toggleStar(row) } },
                    archive: model.offersArchiveAction
                        ? { Task { await model.perform(.archive, onThread: row.id) } }
                        : nil,
                    restoreTitle: model.restoreActionTitle,
                    restore: model.restoreAction.map { action in
                        { Task<Void, Never> { await model.perform(action, onThread: row.id) } }
                    },
                    // In the Trash there is nothing to trash: the rotor action goes
                    // away rather than offering a no-op.
                    trash: model.offersTrashAction
                        ? { Task { await model.perform(.trash, onThread: row.id) } }
                        : nil,
                    openThread: row.messageCount > 1 ? { model.openThread(row.id) } : nil
                )
                .tag(row.id)
                // The row draws its own padding (14/7 × 12, handoff §3.1).
                .listRowInsets(EdgeInsets())
                // Selection itself drills into a multi-message thread (see
                // MailViewModel.selectedThreadID). No tap gesture here: issue #4 —
                // a simultaneous TapGesture on the row content raced the List's own
                // selection, so clicks on text often failed to select at all.
            }
            // Scrolling to the end pages in more. Keyed on `loadMoreTrigger` so
            // the row is a NEW view only after a load that made progress: one
            // still on screen (a short page) fires again, while a load that
            // added nothing visible (a filtered list, a server page of other
            // rows) or failed waits for the next scroll back to the end.
            if model.canLoadMoreConversations {
                LoadMoreRow(isLoading: model.isLoadingMoreConversations)
                    .id(model.loadMoreTrigger)
                    .onAppear { Task { await model.loadMoreConversations() } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(AccessibilityID.MailList.list)
        // The row's own `minHeight` cannot win this one: macOS `List` is an
        // NSTableView that caches a measured height per row identity, and a
        // freshly inserted row it has not measured yet is drawn at
        // `defaultMinListRowHeight` — 24pt by default, which is exactly the
        // one-line row new mail was arriving as. Raise the FLOOR to a full row
        // of the current density.
        .environment(\.defaultMinListRowHeight, rowHeight)
        // Mail's single-key triage, scoped to this list's focus. As a toolbar or
        // menu shortcut these are window-global and fire while the user is typing
        // in the search field — which is how a bare ⌫ deletes the wrong thing.
        // `e` follows the same folder rule ⌘⇧A does: archive where archiving
        // means something, put back in the Trash and the Archive where it does
        // not (the server would ignore an archive there).
        .onKeyPress("e") { act(model.restoreAction ?? .archive) }
        .onKeyPress(.delete) { act(.trash) }
        // Re-entering a thread the user already backed out of: the selection is
        // unchanged, so nothing else would fire.
        .onKeyPress(.return) {
            guard model.selectedThreadID != nil else { return .ignored }
            model.openSelectedThreadViaShortcut()
            return .handled
        }
        .listSearchField(model: model, text: $searchText)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let description = model.serverSearchDescription {
                SearchStatusBar(description: description, state: model.serverSearchState)
            }
        }
        .overlay {
            // Not while a scope/folder change is loading: the list is cleared
            // at once, and "Nothing in Inbox" would flash before the rows land.
            if model.presentedConversations.isEmpty, !model.isLoadingConversations {
                // "Nothing in Sent / in acme.co", or "No Results" while a
                // search filters the list (see `ListColumn.emptyState`).
                ListEmptyStateView(state: model.listEmptyState)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let row = model.presentedConversations.first(where: { $0.id == id }) {
                // First, and in the Message menu's order with its shortcuts, so
                // the right-click menu mirrors the header (issue #11). They reply
                // to the thread's LATEST message — the one the row draws — rather
                // than to whatever the reading pane has selected: the menu fires
                // on the row under the cursor, which need not be the selection.
                //
                // A multiple selection disables them: there is one composer and
                // one reply target, so the only honest answer for several threads
                // is "not this menu". The triage verbs below are the ones that
                // fan out.
                let offersReply = Self.offersReplyActions(for: ids)
                Button("Reply") { model.requestCompose(.reply, onThread: id) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!offersReply)
                Button("Reply All") { model.requestCompose(.replyAll, onThread: id) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!offersReply)
                Button("Forward") { model.requestCompose(.forward, onThread: id) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!offersReply)

                Divider()

                Button(row.isUnread ? "Mark as Read" : "Mark as Unread") {
                    Task { await model.toggleRead(row) }
                }
                Button(row.isStarred ? "Unstar" : "Star") { Task { await model.toggleStar(row) } }
                Divider()
                if model.offersArchiveAction {
                    Button("Archive") { Task { await model.perform(.archive, onThread: id) } }
                }
                // "Put Back" in the Trash, "Move to Inbox" in the Archive —
                // upstream 1.3.4's restore/unarchive (issue #7, #8).
                if let restore = model.restoreAction {
                    Button(model.restoreActionTitle) {
                        Task { await model.perform(restore, onThread: id) }
                    }
                }
                if model.offersTrashAction {
                    Button("Move to Trash", role: .destructive) {
                        Task { await model.perform(.trash, onThread: id) }
                    }
                }
                LabelMenu(model: model, threadID: id)
            }
        }
    }

    /// Whether the context menu's Reply / Reply All / Forward rows are live.
    ///
    /// Pure and static so the rule is assertable without a rendered menu: one
    /// composer, one reply target, so anything but a single row is dimmed.
    nonisolated static func offersReplyActions(for ids: Set<String>) -> Bool {
        ids.count == 1
    }

    /// Runs a single-key action against the selection, and passes the key on when
    /// there is nothing selected.
    private func act(_ action: ConversationAction) -> KeyPress.Result {
        guard model.selectedThreadID != nil else { return .ignored }
        Task { await model.performOnSelection(action) }
        return .handled
    }
}

/// The "Labels" submenu of a conversation's context menu.
///
/// A toggle per label rather than an add list and a remove list: assignment is a
/// membership, so a checkmark says the current state and one click flips it.
/// Renders nothing when the workspace has no labels — an empty submenu is a dead
/// end the user has to open to discover.
struct LabelMenu: View {
    @Bindable var model: MailViewModel
    let threadID: String

    var body: some View {
        if !model.labels.isEmpty {
            Divider()
            Menu(MailTheme.labelsSectionTitle) {
                ForEach(model.labels) { label in
                    // Read through the model in the GETTER, never a value snapshotted
                    // at body-evaluation time: an open menu has to show the checkmark
                    // move when the toggle is flipped.
                    Toggle(label.name, isOn: Binding(
                        get: { model.threadHasLabel(label.id, threadID: threadID) },
                        set: { newValue in
                            Task { await model.setLabel(label.id, onThread: threadID, assigned: newValue) }
                        }
                    ))
                }
            }
        }
    }
}

/// The list's last row while more conversations can be paged in: a small
/// spinner while a page loads (blank otherwise), not selectable.
///
/// The row stays hidden from VoiceOver — an idle, blank element would be a
/// focus stop with nothing on it — so the load is conveyed by an announcement
/// when it starts instead.
struct LoadMoreRow: View {
    let isLoading: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .opacity(isLoading ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.vertical, MailTheme.Spacing.sm)
        .listRowInsets(EdgeInsets())
        .selectionDisabled()
        .accessibilityHidden(true)
        .onChange(of: isLoading) { _, loading in
            guard loading else { return }
            AccessibilityNotification.Announcement(Self.loadingAnnouncement).post()
        }
    }

    static let loadingAnnouncement = String(localized: "Loading more conversations")
}

/// What the SERVER half of a two-tier search is doing, under the list.
///
/// A bar rather than an alert or a toast: the local results are already usable,
/// so the server tier is progress information — including its failures, which
/// are "you are seeing less than everything", not "something went wrong".
struct SearchStatusBar: View {
    let description: String
    let state: MailViewModel.ServerSearchState

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            if state == .searching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else if isFailure {
                Image(systemName: MailTheme.Symbol.warning)
                    .foregroundStyle(MailTheme.failure)
                    .accessibilityHidden(true)
            }
            Text(description)
                .font(MailTheme.Typography.statusBar)
                .foregroundStyle(isFailure ? MailTheme.failure : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.xs)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // One live-announcing element: VoiceOver should hear "searching" and the
        // count without the user hunting for a bar that appears and vanishes.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description)
        // Announce the RESULT, never the "Searching…" step: the bar's text
        // changes on every debounced keystroke while a search runs, and speaking
        // each one would talk over the user typing. Settled states only.
        // Keyed on the STATE, not on the text: two different searches can settle
        // on the same sentence ("No additional results"), and a text-keyed
        // `onChange` would stay silent for the second one.
        .onChange(of: state) { _, newState in
            guard SearchStatusBar.announces(newState) else { return }
            AccessibilityNotification.Announcement(description).post()
        }
    }

    /// Whether a server-search state is worth interrupting the user for: what the
    /// server found, or that it failed. Pure and static so it is assertable.
    nonisolated static func announces(_ state: MailViewModel.ServerSearchState) -> Bool {
        switch state {
        case .idle, .searching: false
        case .completed, .failed: true
        }
    }
}

/// A row's trailing date (`meta`, mono 11). The short form is ambiguous by
/// design ("Tue"), so the absolute date rides along as the tooltip, and the
/// row's accessibility value carries it for VoiceOver.
///
/// `.tertiary`, not `ink3`: it is drawn inside `List` rows, where only the
/// hierarchical styles flip with the system selection.
struct RowDateLabel: View {
    let date: Date

    var body: some View {
        Text(RowDateFormatter.compact(date))
            .textStyle(MailTheme.Typography.meta)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(RowDateFormatter.full(date))
            .accessibilityHidden(true)
    }
}

/// The unread dot at the head of a row: 8pt accent, or nothing. Never the only
/// cue — the sender and subject go semibold too.
///
/// On a SELECTED row the dot turns `.primary` (white on the focused system
/// selection): an accent dot on an accent fill would disappear.
struct UnreadDot: View {
    let isUnread: Bool
    var isSelected = false

    var body: some View {
        Circle()
            .fill(isUnread ? (isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(MailTheme.unreadIndicator)) : AnyShapeStyle(.clear))
            .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
            .accessibilityHidden(true)
    }
}

/// One conversation (handoff §3.1 "Conversation row"): dot | text | trailing,
/// with the attribution the scope leaves open (§2) leading the sender.
///
/// Comfortable: `[AC] sales@ · Sender` / subject / a two-line snippet.
/// Compact: `[AC] sales@ · Sender  Subject` / a one-line snippet.
/// Label chips (≤3, then +n) close either. Trailing: the date over
/// [count][star][chevron when the thread has more than one message].
struct ConversationRow: View {
    let row: ConversationSummary
    /// The committed search query, marked up inside subject and snippet. Empty
    /// when nothing is being searched, which costs one plain `AttributedString`.
    var highlight: String = ""
    /// What the scope leaves open: badge + mailbox, mailbox, or nothing.
    let attribution: ListColumn.Attribution
    /// The account's tint — the domain badge's wash.
    let accountTint: MailTheme.AccountTint?
    let metrics: ListColumn.RowMetrics
    /// A full row's height for the density (the list's unmeasured-row floor).
    let minHeight: CGFloat
    var isSelected = false
    /// The labels on ANY message of the thread, in sidebar order. Empty for most
    /// rows, and the chip row renders nothing at all then.
    var labels: [MailLabel] = []
    let toggleStar: () -> Void
    /// `nil` in Trash and Archive, where archiving is a server no-op.
    let archive: (() -> Void)?
    /// The put-back verb and its action, non-nil only in Trash and Archive. The
    /// title is the one the context menu shows, so VoiceOver and the menu cannot
    /// drift apart.
    let restoreTitle: String
    let restore: (() -> Void)?
    /// `nil` in the Trash, where trashing is a no-op.
    let trash: (() -> Void)?
    /// Non-nil when the conversation has more than one message.
    let openThread: (() -> Void)?

    private var lines: ListColumn.LineHeights { .current }

    var body: some View {
        HStack(alignment: .top, spacing: ListColumn.Layout.rowColumnGap) {
            VStack(alignment: .leading, spacing: ListColumn.Layout.lineGap) {
                firstLine
                if !metrics.subjectInline { subjectLabel }
                HStack(alignment: .firstTextBaseline, spacing: MailTheme.Spacing.xs) {
                    if row.latest.hasAttachments {
                        Image(systemName: MailTheme.Symbol.attachment)
                            .font(MailTheme.Typography.inlineGlyph)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(SearchHighlighter.highlight(
                        SnippetCleaner.clean(row.latest.snippet), matching: highlight
                    ))
                    .textStyle(MailTheme.Typography.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(metrics.snippetLines)
                }
                // Last line, under the snippet: labels are metadata about the
                // thread, not part of what it says.
                LabelChipRow(labels: labels, isSelected: isSelected)
            }
            // COMBINE, not `contain`: as a container VoiceOver stopped on each
            // Text separately and the row's own label — the only place
            // unread/starred/attachments are spoken — was never read.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Self.accessibilitySummary(for: row, mailboxName: attribution.spoken, labels: labels)
            )
            // The full date, not the "Tue" on screen: the short form is not a date.
            .accessibilityValue(RowDateFormatter.full(row.latest.displayDate))
            .accessibilityIdentifier(AccessibilityID.MailList.rowPrefix + row.id)

            trailingColumn
        }
        .padding(.vertical, metrics.verticalPadding)
        .padding(.horizontal, ListColumn.Layout.rowHorizontalPadding)
        // The dot hangs in the leading padding rather than owning a column, so
        // the text starts at the same 12pt edge the trailing column ends at.
        .overlay(alignment: .topLeading) {
            UnreadDot(isUnread: row.isUnread, isSelected: isSelected)
                .frame(width: ListColumn.Layout.rowHorizontalPadding)
                .padding(.top, metrics.verticalPadding + (firstLineHeight - MailTheme.unreadDotDiameter) / 2)
        }
        // Stable minimum height + no vertical compression: see the list's
        // `defaultMinListRowHeight`, which is the same number.
        .frame(minHeight: minHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .selectionOutline(isSelected)
        // The triage verbs, reachable from the VoiceOver rotor rather than only
        // from the menu bar or a right-click.
        .accessibilityAction(named: row.isStarred ? "Unstar" : "Star", toggleStar)
        // A container, so a scope that cannot archive (or trash, or put back)
        // offers no rotor entry at all rather than one that does nothing.
        .accessibilityActions {
            if let archive { Button("Archive", action: archive) }
            if let restore { Button(restoreTitle, action: restore) }
            if let trash { Button("Move to Trash", action: trash) }
        }
    }

    /// The badge is 16pt, taller than a line of text; line 1 is whichever wins.
    private var firstLineHeight: CGFloat { max(lines.body, ListColumn.Layout.badgeRowHeight) }

    /// Attribution, then the sender (the part that truncates first after the
    /// subject), then — in Compact — the subject on the same line.
    private var firstLine: some View {
        HStack(spacing: ListColumn.Layout.attributionGap) {
            if !attribution.isEmpty {
                RowAttributionView(attribution: attribution, tint: accountTint, isSelected: isSelected)
            }
            Text(Self.displayParticipants(for: row))
                .textStyle(row.isUnread ? MailTheme.Typography.headline : MailTheme.Typography.bodyMedium)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if metrics.subjectInline {
                subjectLabel
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: ListColumn.Layout.badgeRowHeight)
    }

    private var subjectLabel: some View {
        Text(SearchHighlighter.highlight(subjectText, matching: highlight))
            .textStyle(row.isUnread ? MailTheme.Typography.headline : MailTheme.Typography.body)
            .lineLimit(1)
    }

    /// Date on top; [count][star][chevron] beneath it (handoff §3.1).
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            RowDateLabel(date: row.latest.displayDate)
            HStack(spacing: 0) {
                if row.messageCount > 1 {
                    CountPill(count: row.messageCount, isSelected: isSelected)
                }
                // Its own element on purpose: it is a control, and folding it
                // into the row would cost the only way to star without the mouse.
                Button(action: toggleStar) {
                    Image(systemName: row.isStarred ? "star.fill" : "star")
                        .foregroundStyle(row.isStarred ? AnyShapeStyle(MailTheme.starred) : AnyShapeStyle(.tertiary))
                        .iconButtonStyle(row.isStarred ? "Unstar" : "Star")
                }
                .buttonStyle(.plain)
                if let openThread {
                    // A real button, not a decorative chevron: re-entering a
                    // thread has to work from the keyboard and the rotor, not
                    // only by re-clicking an already-selected row.
                    Button(action: openThread) {
                        Image(systemName: MailTheme.Symbol.drillDown)
                            .foregroundStyle(.tertiary)
                            .iconButtonStyle("Show \(row.messageCount) messages")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fixedSize()
    }

    private var subjectText: String {
        row.latest.subject.isEmpty ? "(No subject)" : row.latest.subject
    }

    /// Who the row names on screen: the sender's display name, or — for a
    /// thread whose latest message is the user's own — "To:" and its
    /// recipients.
    nonisolated static func displayParticipants(for row: ConversationSummary) -> String {
        row.latest.direction == .outbound
            ? "To: " + row.latest.to.map(ListColumn.senderName).joined(separator: ", ")
            : ListColumn.senderName(row.latest.fromAddress)
    }

    private nonisolated static func participants(for row: ConversationSummary) -> String {
        row.latest.direction == .outbound
            ? "To: " + row.latest.to.joined(separator: ", ")
            : row.latest.fromAddress
    }

    /// What VoiceOver reads for one row. Internal and pure so the states that are
    /// easiest to drop — unread, starred, attachments, and the mailbox a row is
    /// attributed to — are assertable without a rendered list.
    ///
    /// The attribution leads, matching its position on screen.
    nonisolated static func accessibilitySummary(
        for row: ConversationSummary,
        mailboxName: String? = nil,
        labels: [MailLabel] = []
    ) -> String {
        var parts: [String] = []
        if let mailboxName { parts.append(mailboxName) }
        parts.append(participants(for: row))
        parts.append(row.latest.subject.isEmpty ? "No subject" : row.latest.subject)
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.isUnread { parts.append("unread") }
        if row.isStarred { parts.append("starred") }
        if row.latest.hasAttachments { parts.append("has attachments") }
        // The chips are `accessibilityHidden`, so this is the ONLY place a
        // VoiceOver user hears which labels a row carries.
        if let phrase = LabelChipRow.accessibilityPhrase(for: labels) { parts.append(phrase) }
        // The CLEANED preview the row draws, not the raw server snippet (quoted
        // history, "On … wrote:", entities) that sighted users never see.
        parts.append(SnippetCleaner.clean(row.latest.snippet))
        return parts.joined(separator: ", ")
    }
}

/// A thread's message count on its row (mono 10 on the neutral chip fill).
/// Spoken in the row summary, so hidden here. On a selected row the fill turns
/// hierarchical with the text (``MailTheme/rowChipBackground(isSelected:)``).
struct CountPill: View {
    let count: Int
    var isSelected = false

    var body: some View {
        Text("\(count)")
            .textStyle(MailTheme.Typography.count)
            .foregroundStyle(.secondary)
            .padding(.horizontal, MailTheme.Spacing.xs + MailTheme.Spacing.xxs)
            .padding(.vertical, MailTheme.Spacing.xxs / 2)
            .background(MailTheme.rowChipBackground(isSelected: isSelected), in: Capsule())
            .accessibilityHidden(true)
    }
}

/// The toolbar search field, shared by the conversation list and the Drafts
/// list so the field neither disappears nor shifts the toolbar when the user
/// switches into Drafts. The text is owned by ``MiddleColumnView``; this
/// debounces it into `model.searchQuery`, which both lists filter by.
private struct ListSearchField: ViewModifier {
    @Bindable var model: MailViewModel
    @Binding var text: String
    /// ⌘F focus. `@FocusState` cannot be reached from `Commands`, which is why
    /// the shortcut rides on a hidden button here instead of the menu bar.
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            // The native toolbar field (handoff §3.1); the prompt names the scope
            // a search covers — "Search all domains", "Search acme.co".
            .searchable(text: $text, placement: .toolbar, prompt: Text(model.searchPrompt))
            .searchFocused($focused)
            // Return in the search field searches the SERVER for what is on
            // screen; the local pass has already run on every keystroke.
            .onSubmit(of: .search) { model.submitSearch() }
            .task(id: text) {
                guard text != model.searchQuery else { return }
                // Clearing is not typing: it needs no debounce, and waiting to
                // apply it leaves the old needle's rows on screen under an empty
                // field. That window is also what an ACCOUNT SWITCH walks into —
                // the column is `.id(accountID)`-reset, so the field comes back
                // empty while the incoming account's view-model still holds its
                // previous query.
                guard !text.isEmpty else {
                    model.searchQuery = ""
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                model.searchQuery = text
            }
            // ⌘F, the standard macOS Find. Hidden from accessibility: the search
            // field is already reachable, this is only the shortcut's carrier.
            .background {
                Button("Find") { focused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func listSearchField(model: MailViewModel, text: Binding<String>) -> some View {
        modifier(ListSearchField(model: model, text: text))
    }
}
