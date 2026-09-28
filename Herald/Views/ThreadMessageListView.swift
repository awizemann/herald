import HeraldKit
import SwiftUI

/// One drilled-into thread (handoff §3.1 "Thread view"): a "‹ {folder}" back
/// link, the subject with the attribution the scope leaves open and "N messages
/// · M people", then a row per message, newest first with the newest selected.
///
/// A `List` with a selection binding, not a hand-rolled `LazyVStack` of buttons:
/// arrowing between messages is then the list's own behaviour rather than two
/// `.onKeyPress` handlers that only work while the stack happens to be focused.
struct ThreadMessageListView: View {
    @Bindable var model: MailViewModel
    let metrics: ListColumn.RowMetrics

    private var folderTitle: String { ListColumn.folderTitle(model.folder) }

    var body: some View {
        // Once per pass, like the conversation list.
        let ownAddresses = model.ownAddressKeys
        let accountTint = model.listAccountTint
        let rowHeight = metrics.messageRowHeight(.current)
        VStack(spacing: 0) {
            backLink
            header
            List(model.threadMessages, selection: $model.selectedMessageID) { message in
                ThreadMessageRow(
                    message: message,
                    isOwn: ListColumn.isOwnMessage(message, ownAddresses: ownAddresses),
                    accountTint: accountTint,
                    metrics: metrics,
                    minHeight: rowHeight,
                    isSelected: model.selectedMessageID == message.id,
                    toggleStar: {
                        Task { await model.perform(message.isStarred ? .unstar : .star, on: message.id) }
                    }
                )
                .tag(message.id)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Same unmeasured-row floor as the conversation list.
            .environment(\.defaultMinListRowHeight, rowHeight)
        }
        // ⎋ backs out, as it does everywhere else on macOS; ⌘[ does the same from
        // a hidden carrier beside the back link (see `backLink`).
        .onExitCommand { model.exitThreadViaShortcut() }
    }

    /// "‹ Inbox" — the folder the thread was opened from.
    private var backLink: some View {
        HStack {
            Button { model.exitThread() } label: {
                BackLinkLabel(title: folderTitle)
            }
            .buttonStyle(.plain)
            .help("Back to \(folderTitle)")
            .accessibilityLabel("Back to \(folderTitle)")
            .accessibilityIdentifier(AccessibilityID.MailList.threadBack)
            // ⌘[ carries the same step on a hidden button of its own, next to
            // the control it belongs to: a `keyboardShortcut` ON the link
            // cannot tell the key press from the click, and the two are
            // different ways of getting here. Hidden from accessibility — the
            // link beside it is the reachable control.
            .background {
                Button("Back") { model.exitThreadViaShortcut() }
                    .keyboardShortcut("[", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        // The design's 12pt, less what the link's 28pt hit frame already adds
        // above its ~16pt line — so the text sits where the design puts it.
        .padding(.top, ListColumn.Layout.threadBackTopPadding - MailTheme.Spacing.sm)
        .padding(.horizontal, ListColumn.Layout.threadBackHorizontalPadding)
    }

    private var header: some View {
        let conversation = model.selectedConversation
        let attribution = model.rowAttributionIndex().attribution(forMailbox: conversation?.latest.mailboxID)
        let summary = Self.headerSummary(model.threadMessages)
        return VStack(alignment: .leading, spacing: ListColumn.Layout.threadHeaderGap) {
            Text(subject)
                .textStyle(MailTheme.Typography.threadTitle)
                .foregroundStyle(MailTheme.Color.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityID.MailList.threadSubject)
            HStack(spacing: ListColumn.Layout.attributionGap) {
                if !attribution.isEmpty {
                    RowAttributionView(attribution: attribution, tint: model.listAccountTint)
                }
                if let summary {
                    Text(summary)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .lineLimit(1)
                }
            }
            // Holds the line's height while the messages load, so the header
            // does not grow a line when the summary arrives.
            .frame(minHeight: ListColumn.Layout.badgeRowHeight, alignment: .leading)
            // One sentence for VoiceOver: "sales@acme.co, 5 messages · 3 people".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                [attribution.spoken, summary].compactMap { $0 }.joined(separator: ", ")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ListColumn.Layout.threadHeaderTopPadding)
        .padding(.horizontal, ListColumn.Layout.headerHorizontalPadding)
        .padding(.bottom, ListColumn.Layout.threadHeaderBottomPadding)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MailTheme.Color.lineSoft)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private var subject: String {
        let subject = model.selectedConversation?.latest.subject ?? ""
        return subject.isEmpty ? "(No subject)" : subject
    }

    /// "5 messages · 3 people", or `nil` while the thread's messages are still
    /// loading — selecting a thread clears `threadMessages` until
    /// `loadThread` fills it, and "0 messages · 0 people" there is a lie about
    /// a thread the user can see has messages.
    nonisolated static func headerSummary(_ messages: [MessageSummary]) -> String? {
        messages.isEmpty ? nil : ListColumn.threadSummary(messages)
    }
}

/// The back link's face: `chevron.left` + the folder, ink2 → ink on hover,
/// padded to the 28pt hit target.
private struct BackLinkLabel: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xxs) {
            Image(systemName: "chevron.left")
                .font(MailTheme.Typography.backChevronGlyph)
            Text(title)
                .textStyle(MailTheme.Typography.snippet)
        }
        .foregroundStyle(isHovering ? MailTheme.Color.ink : MailTheme.Color.ink2)
        .frame(minHeight: MailTheme.hitTarget)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : MailTheme.Animation.micro) { isHovering = hovering }
        }
    }
}

/// One message inside a drilled-into thread: avatar | sender, To:, snippet |
/// date over star. No attribution — the thread header carries it once.
struct ThreadMessageRow: View {
    let message: MessageSummary
    /// The user's own message: its avatar takes the account tint.
    let isOwn: Bool
    let accountTint: MailTheme.AccountTint?
    let metrics: ListColumn.RowMetrics
    let minHeight: CGFloat
    var isSelected = false
    let toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ListColumn.Layout.rowColumnGap) {
            ThreadAvatar(
                initials: ListColumn.initials(message.fromAddress),
                tint: isOwn ? accountTint : nil,
                isUnread: message.isUnread,
                isSelected: isSelected
            )

            VStack(alignment: .leading, spacing: ListColumn.Layout.messageLineGap) {
                Text(ListColumn.senderName(message.fromAddress))
                    .textStyle(message.isUnread ? MailTheme.Typography.headline : MailTheme.Typography.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("To: \(message.to.map(ListColumn.senderName).joined(separator: ", "))")
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(SnippetCleaner.clean(message.snippet))
                    .textStyle(MailTheme.Typography.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(metrics.snippetLines)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilitySummary(for: message))
            .accessibilityValue(RowDateFormatter.full(message.displayDate))
            .accessibilityIdentifier(AccessibilityID.MailList.messageRowPrefix + message.id)

            Spacer(minLength: 0)

            // Same trailing column as a conversation row: date on top, star under it.
            VStack(alignment: .trailing, spacing: 0) {
                RowDateLabel(date: message.displayDate)
                Button(action: toggleStar) {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? AnyShapeStyle(MailTheme.starred) : AnyShapeStyle(.tertiary))
                        .iconButtonStyle(message.isStarred ? "Unstar" : "Star")
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
        .accessibilityAction(named: message.isStarred ? "Unstar" : "Star", toggleStar)
    }

    /// What VoiceOver reads for one message row: on screen the state is a dot, a
    /// bold weight and a star, none of which say anything out loud.
    nonisolated static func accessibilitySummary(for message: MessageSummary) -> String {
        var parts: [String] = []
        parts.append(message.fromAddress)
        parts.append("To: \(message.to.joined(separator: ", "))")
        if message.isUnread { parts.append("unread") }
        if message.isStarred { parts.append("starred") }
        // The cleaned preview the row draws, not the raw server snippet.
        parts.append(SnippetCleaner.clean(message.snippet))
        return parts.joined(separator: ", ")
    }
}

/// A thread row's 28pt initials avatar: neutral (`lineSoft`, ink2) for other
/// people, the account tint (solid, avatar-text initials) for the user's own
/// messages. The unread dot sits on its top-left edge, ringed in the list
/// background so it reads against either fill. Decorative — the row summary
/// speaks sender and unread state.
///
/// On a SELECTED row the dot turns `.primary` (white on the focused accent
/// selection, like ``UnreadDot``) and loses its ring: a `bg`-coloured ring
/// would cut a pale hole out of the selection fill around it.
struct ThreadAvatar: View {
    let initials: String
    /// Non-nil for the user's own message.
    let tint: MailTheme.AccountTint?
    let isUnread: Bool
    var isSelected = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(tint?.solid ?? MailTheme.Color.lineSoft)
                .overlay {
                    Text(initials)
                        .font(MailTheme.Typography.avatarInitials.font)
                        .foregroundStyle(tint?.avatarText ?? MailTheme.Color.ink2)
                }
                .frame(width: ListColumn.Layout.avatarDiameter, height: ListColumn.Layout.avatarDiameter)
            if isUnread {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(MailTheme.unreadIndicator))
                    .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                    .background(
                        Circle()
                            .fill(isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(MailTheme.Color.bg))
                            .padding(-ListColumn.Layout.dotRingWidth)
                    )
                    // The design's top −2 / left −4.
                    .offset(x: -MailTheme.Spacing.xs, y: -MailTheme.Spacing.xxs)
            }
        }
        .accessibilityHidden(true)
    }
}
