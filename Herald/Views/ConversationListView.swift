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

    var body: some View {
        ZStack {
            if model.isShowingThread {
                ThreadMessageListView(model: model)
                    .transition(.opacity)
            } else {
                ConversationListView(model: model, searchText: $searchText)
                    .transition(.opacity)
            }
        }
        // A cross-fade, and none at all when the user asked for less motion.
        .animation(reduceMotion ? nil : MailTheme.Animation.quick, value: model.isShowingThread)
    }
}

/// The conversation rows for the selected scope.
struct ConversationListView: View {
    @Bindable var model: MailViewModel
    /// Search text, owned by ``MiddleColumnView`` so it survives a drill-in, and
    /// debounced here before it reaches the view-model — so a keystroke never
    /// re-runs the list's data source (or the detail pane).
    @Binding var searchText: String
    /// ⌘F focus. `@FocusState` cannot be reached from `Commands`, which is why
    /// the shortcut rides on a hidden button in this view instead of the menu bar.
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        List(model.presentedConversations, selection: $model.selectedThreadID) { row in
            ConversationRow(
                row: row,
                // The COMMITTED query, not the field's text: the rows on screen
                // were filtered with this one, so marking them with a needle the
                // user is still typing would highlight what is not matched yet.
                highlight: model.searchQuery,
                // Only in the all-mailboxes scope: with a mailbox picked, every
                // row would carry the same chip and say nothing.
                mailboxName: model.selection.mailboxID == nil
                    ? model.mailboxName(for: row.latest.mailboxID)
                    : nil,
                mailboxTint: model.selection.mailboxID == nil
                    ? model.mailboxTint(for: row.latest.mailboxID)
                    : nil,
                toggleStar: { Task { await model.toggleStar(row) } },
                archiveTitle: model.archiveActionTitle,
                archive: { Task { await model.perform(.archive, onThread: row.id) } },
                // In the Trash there is nothing to trash: the rotor action goes
                // away rather than offering a no-op.
                trash: model.offersTrashAction
                    ? { Task { await model.perform(.trash, onThread: row.id) } }
                    : nil,
                openThread: row.messageCount > 1 ? { model.openThread(row.id) } : nil
            )
            .tag(row.id)
            // Selection itself drills into a multi-message thread (see
            // MailViewModel.selectedThreadID). No tap gesture here: issue #4 —
            // a simultaneous TapGesture on the row content raced the List's own
            // selection, so clicks on text often failed to select at all.
        }
        .listStyle(.inset)
        // The row's own `minHeight` cannot win this one: macOS `List` is an
        // NSTableView that caches a measured height per row identity, and a
        // freshly inserted row it has not measured yet is drawn at
        // `defaultMinListRowHeight` — 24pt by default, which is exactly the
        // one-line row new mail was arriving as. Raise the FLOOR to a full row.
        .environment(\.defaultMinListRowHeight, MailTheme.rowMinHeight)
        // Mail's single-key triage, scoped to this list's focus. As a toolbar or
        // menu shortcut these are window-global and fire while the user is typing
        // in the search field — which is how a bare ⌫ deletes the wrong thing.
        .onKeyPress("e") { act(.archive) }
        .onKeyPress(.delete) { act(.trash) }
        // Re-entering a thread the user already backed out of: the selection is
        // unchanged, so nothing else would fire.
        .onKeyPress(.return) {
            guard model.selectedThreadID != nil else { return .ignored }
            model.openSelectedThread()
            return .handled
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search mail")
        .searchFocused($searchFieldFocused)
        // Return in the search field searches the SERVER for what is on screen;
        // the local pass has already run on every keystroke.
        .onSubmit(of: .search) { model.submitSearch() }
        .task(id: searchText) {
            guard searchText != model.searchQuery else { return }
            // Clearing is not typing: it needs no debounce, and waiting to apply
            // it leaves the old needle's rows on screen under an empty field.
            // That window is also what an ACCOUNT SWITCH walks into — the column
            // is `.id(accountID)`-reset, so the field comes back empty while the
            // incoming account's view-model still holds its previous query.
            guard !searchText.isEmpty else {
                model.searchQuery = ""
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            model.searchQuery = searchText
        }
        // ⌘F, the standard macOS Find. A `Commands` item cannot write this view's
        // `@FocusState`, so the shortcut lives on a hidden button in the window
        // that owns the field. Hidden from accessibility: the search field is
        // already reachable, this is only the shortcut's carrier.
        .background {
            Button("Find") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let description = model.serverSearchDescription {
                SearchStatusBar(description: description, state: model.serverSearchState)
            }
        }
        .overlay {
            if model.presentedConversations.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.searchQuery.isEmpty ? "No Messages" : "No Results",
                        systemImage: MailTheme.symbol(for: model.selection.folder)
                    )
                } description: {
                    // Only worth saying while a search is running and the server
                    // has not been asked yet — otherwise it promises a second
                    // answer that is already on its way (or already in).
                    if !model.searchQuery.isEmpty, model.serverSearchState == .idle {
                        Text("Press Return to search the server.")
                    }
                }
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
                // "Move to Archive" in the Trash: it is a per-message archive,
                // the only way back out the v1 API has (issue #8).
                Button(model.archiveActionTitle) {
                    Task { await model.perform(.archive, onThread: id) }
                }
                if model.offersTrashAction {
                    Button("Move to Trash", role: .destructive) {
                        Task { await model.perform(.trash, onThread: id) }
                    }
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MailTheme.failure)
                    .accessibilityHidden(true)
            }
            Text(description)
                .font(.caption)
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
    }
}

/// One drilled-into thread: a header that gets back out, then a row per message.
///
/// A `List` with a selection binding, not a hand-rolled `LazyVStack` of buttons:
/// arrowing between messages is then the list's own behaviour rather than two
/// `.onKeyPress` handlers that only work while the stack happens to be focused.
struct ThreadMessageListView: View {
    @Bindable var model: MailViewModel

    private var folderTitle: String { MailTheme.title(for: model.selection.folder) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(model.threadMessages, selection: $model.selectedMessageID) { message in
                ThreadMessageRow(
                    message: message,
                    // Same rule as the conversation list: attribution only where
                    // the scope is ambiguous.
                    mailboxName: model.selection.mailboxID == nil
                        ? model.mailboxName(for: message.mailboxID)
                        : nil,
                    mailboxTint: model.selection.mailboxID == nil
                        ? model.mailboxTint(for: message.mailboxID)
                        : nil,
                    toggleStar: {
                        Task { await model.perform(message.isStarred ? .unstar : .star, on: message.id) }
                    }
                )
                .tag(message.id)
            }
            .listStyle(.inset)
            // Same unmeasured-row floor as the conversation list.
            .environment(\.defaultMinListRowHeight, MailTheme.rowMinHeight)
        }
        // ⎋ backs out, as it does everywhere else on macOS. ⌘[ rides on the back
        // button itself so the shortcut and the control cannot drift apart.
        .onExitCommand { model.exitThread() }
    }

    private var header: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Button { model.exitThread() } label: {
                Image(systemName: "chevron.left")
                    .iconButtonStyle("Back to \(folderTitle)")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)

            VStack(alignment: .leading, spacing: 0) {
                Text(subject)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(model.threadMessages.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.xs)
    }

    private var subject: String {
        let subject = model.selectedConversation?.latest.subject ?? ""
        return subject.isEmpty ? "(No subject)" : subject
    }
}

/// One message inside a drilled-into thread.
struct ThreadMessageRow: View {
    let message: MessageSummary
    let mailboxName: String?
    let mailboxTint: MailboxTint?
    let toggleStar: () -> Void

    private var fromLabel: some View {
        Text(message.fromAddress)
            .font(.subheadline)
            .fontWeight(message.isUnread ? .bold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
            // Unread is bold text AND a dot: never color alone.
            Circle()
                .fill(message.isUnread ? MailTheme.unreadIndicator : .clear)
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .padding(.top, MailTheme.Spacing.xs)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                // Same rule as a conversation row: mailbox leads and holds its
                // width, sender gives way first, date keeps its own slot.
                HStack(spacing: MailTheme.Spacing.sm) {
                    if let mailboxName {
                        MailboxChip(name: mailboxName, tint: mailboxTint)
                            .layoutPriority(2)
                    } else {
                        fromLabel
                    }
                    Spacer(minLength: 0)
                }
                if mailboxName != nil { fromLabel }
                Text("To: \(message.to.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(SnippetCleaner.clean(message.snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilitySummary(for: message, mailboxName: mailboxName))
            .accessibilityValue(RowDateFormatter.full(message.displayDate))

            // Same trailing column as a conversation row: date on top, star under it.
            VStack(alignment: .trailing, spacing: 0) {
                RowDateLabel(date: message.displayDate)
                Button(action: toggleStar) {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? MailTheme.starred : .secondary)
                        .iconButtonStyle(message.isStarred ? "Unstar" : "Star")
                }
                .buttonStyle(.plain)
            }
            .frame(width: MailTheme.dateSlotWidth, alignment: .trailing)
        }
        .frame(minHeight: MailTheme.rowMinHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, MailTheme.Spacing.xxs)
        .accessibilityAction(named: message.isStarred ? "Unstar" : "Star", toggleStar)
    }

    /// What VoiceOver reads for one message row: on screen the state is a dot, a
    /// bold weight and a star, none of which say anything out loud.
    nonisolated static func accessibilitySummary(
        for message: MessageSummary,
        mailboxName: String? = nil
    ) -> String {
        var parts: [String] = []
        if let mailboxName { parts.append(mailboxName) }
        parts.append(message.fromAddress)
        parts.append("To: \(message.to.joined(separator: ", "))")
        if message.isUnread { parts.append("unread") }
        if message.isStarred { parts.append("starred") }
        parts.append(message.snippet)
        return parts.joined(separator: ", ")
    }
}

/// Which mailbox a row belongs to, shown only in the all-mailboxes scope, where
/// it is the row's PRIMARY label — the sender reads as secondary next to it.
///
/// Tinted per mailbox, but the name is always drawn: the colour is a second cue
/// on top of text, never the attribution itself, so the chip survives greyscale
/// and Increase Contrast. VoiceOver reads it from the row's own combined label,
/// hence `accessibilityHidden`.
struct MailboxChip: View {
    let name: String
    /// `nil` falls back to the neutral chip surface — an override naming a token
    /// this build no longer ships must still render a readable chip.
    let tint: MailboxTint?

    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tint?.color ?? MailTheme.attributionForeground)
            .lineLimit(1)
            .padding(.horizontal, MailTheme.Spacing.xs)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(background, in: Capsule())
            .accessibilityHidden(true)
    }

    private var background: AnyShapeStyle {
        guard let tint else { return MailTheme.chipBackground }
        return AnyShapeStyle(tint.color.opacity(MailTheme.mailboxChipFillOpacity))
    }
}

/// A row's trailing date: a FIXED-width slot, so a long mailbox name or a long
/// sender runs into its own truncation instead of squeezing the date out — which
/// is what the old free-flowing line did. The short form is ambiguous by design
/// ("Tue"), so the absolute date rides along as the tooltip, and the row's
/// accessibility value carries it for VoiceOver.
struct RowDateLabel: View {
    let date: Date

    var body: some View {
        Text(RowDateFormatter.compact(date))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help(RowDateFormatter.full(date))
            .accessibilityHidden(true)
    }
}

struct ConversationRow: View {
    let row: ConversationSummary
    /// The committed search query, marked up inside subject and snippet. Empty
    /// when nothing is being searched, which costs one plain `AttributedString`.
    var highlight: String = ""
    /// Non-nil only in the all-mailboxes scope.
    let mailboxName: String?
    /// The mailbox's resolved palette tint, resolved by the view-model.
    let mailboxTint: MailboxTint?
    let toggleStar: () -> Void
    /// "Archive", or "Move to Archive" in the Trash — the same verb the context
    /// menu shows, so VoiceOver and the menu cannot drift apart.
    let archiveTitle: String
    let archive: () -> Void
    /// `nil` in the Trash, where trashing is a no-op.
    let trash: (() -> Void)?
    /// Non-nil when the conversation has more than one message.
    let openThread: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
            // Unread is bold text AND a dot: never color alone.
            Circle()
                .fill(row.isUnread ? MailTheme.unreadIndicator : .clear)
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .padding(.top, MailTheme.Spacing.xs)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                HStack(spacing: MailTheme.Spacing.sm) {
                    // Mailbox first and with the higher layout priority: it is
                    // WHICH INBOX this landed in, which the owner reads before the
                    // sender. It never truncates before the sender does.
                    // Owner request 2026-08-16: when the chip is shown, the sender
                    // gets its OWN line beneath it — the two never share a line.
                    if let mailboxName {
                        MailboxChip(name: mailboxName, tint: mailboxTint)
                            .layoutPriority(2)
                    } else {
                        participantsLabel
                    }
                    Spacer(minLength: 0)
                }
                if mailboxName != nil { participantsLabel }
                Text(SearchHighlighter.highlight(subjectText, matching: highlight))
                    .font(.body)
                    .fontWeight(row.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: MailTheme.Spacing.xs) {
                    if row.latest.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(SearchHighlighter.highlight(
                        SnippetCleaner.clean(row.latest.snippet), matching: highlight
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            // COMBINE, not the row's old `contain`: as a container VoiceOver
            // stopped on each Text separately and the row's own label — the only
            // place unread/starred/attachments were spoken — was never read.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilitySummary(for: row, mailboxName: mailboxName))
            // The full date, not the "Tue" on screen: the short form is not a date.
            .accessibilityValue(RowDateFormatter.full(row.latest.displayDate))

            // Trailing column: star (and the open-thread chevron) on top, the
            // message count beneath — off the crowded first line, where it can
            // be read at a glance and doesn't compete with the chip or the date.
            // Trailing column, FIXED width so every row lines up: the date on top,
            // right-justified at the row's edge, then the tools beneath it —
            // chevron (or an equal-sized blank), star, message count.
            VStack(alignment: .trailing, spacing: 0) {
                RowDateLabel(date: row.latest.displayDate)
                // Line 2: [count][chevron] — the count sits LEFT of the arrow, and
                // a single-message row keeps an equal-sized blank so every row's
                // text column has the same width.
                HStack(spacing: MailTheme.Spacing.xxs) {
                    if row.messageCount > 1 {
                        Text("\(row.messageCount)")
                            .font(.caption2)
                            .monospacedDigit()
                            .padding(.horizontal, MailTheme.Spacing.xs)
                            .padding(.vertical, MailTheme.Spacing.xxs)
                            .background(MailTheme.chipBackground, in: Capsule())
                            .accessibilityHidden(true) // spoken in the row summary
                    }
                    if let openThread {
                        // A real button, not a decorative chevron: re-entering a
                        // thread has to work from the keyboard and the rotor, not
                        // only by re-clicking an already-selected row.
                        Button(action: openThread) {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .iconButtonStyle("Show \(row.messageCount) messages")
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                            .accessibilityHidden(true)
                    }
                }
                // Its own element on purpose: it is a control, and folding it
                // into the row would cost the only way to star without the mouse.
                Button(action: toggleStar) {
                    Image(systemName: row.isStarred ? "star.fill" : "star")
                        .foregroundStyle(row.isStarred ? MailTheme.starred : .secondary)
                        .iconButtonStyle(row.isStarred ? "Unstar" : "Star")
                }
                .buttonStyle(.plain)
            }
            .frame(width: MailTheme.dateSlotWidth, alignment: .trailing)
        }
        // Stable minimum height + no vertical compression: see MailTheme.rowMinHeight.
        .frame(minHeight: MailTheme.rowMinHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, MailTheme.Spacing.xxs)
        // The triage verbs, reachable from the VoiceOver rotor rather than only
        // from the menu bar or a right-click.
        .accessibilityAction(named: row.isStarred ? "Unstar" : "Star", toggleStar)
        .accessibilityAction(named: archiveTitle, archive)
        // A container, so the Trash scope offers no trash action at all rather
        // than a rotor entry that does nothing.
        .accessibilityActions {
            if let trash { Button("Move to Trash", action: trash) }
        }
    }

    private var subjectText: String {
        row.latest.subject.isEmpty ? "(No subject)" : row.latest.subject
    }

    private var participants: String { Self.participants(for: row) }

    private var participantsLabel: some View {
        Text(participants)
            .font(.subheadline)
            .fontWeight(row.isUnread ? .bold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(2)
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
    /// The mailbox leads, matching the chip's new position: it is the row's
    /// primary label on screen and has to be the first thing spoken too.
    nonisolated static func accessibilitySummary(
        for row: ConversationSummary,
        mailboxName: String? = nil
    ) -> String {
        var parts: [String] = []
        if let mailboxName { parts.append(mailboxName) }
        parts.append(participants(for: row))
        parts.append(row.latest.subject.isEmpty ? "No subject" : row.latest.subject)
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.isUnread { parts.append("unread") }
        if row.isStarred { parts.append("starred") }
        if row.latest.hasAttachments { parts.append("has attachments") }
        parts.append(row.latest.snippet)
        return parts.joined(separator: ", ")
    }
}
