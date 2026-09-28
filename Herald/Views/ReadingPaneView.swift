import HeraldKit
// `.quickLookPreview` is a QuickLook-provided SwiftUI modifier, not a SwiftUI one.
import QuickLook
import SwiftUI

/// Detail pane: the ONE selected message, full height.
///
/// The in-pane list of every message in the thread is gone — picking a message
/// is the middle column's job now (see `ThreadMessageListView`), and keeping a
/// second copy here both duplicated the control and stole ~160pt from the body.
///
/// Redesign R6: the old two-header layout (a thread-subject bar carrying the
/// reply/label/triage buttons, then a second header for the message itself) is
/// one merged header now — "Message N of M", the subject, then the sender
/// block — and every one of those buttons moved to the window toolbar
/// (`RootView.toolbar`), in the design's order. This view stays a pure
/// presenter of `MailViewModel`'s existing thread/selection state; it adds no
/// state of its own.
struct ReadingPaneView: View {
    @Bindable var model: MailViewModel

    var body: some View {
        Group {
            if model.selectedThreadID == nil {
                ReadingPaneEmptyState()
            } else {
                content
            }
        }
        .frame(minWidth: Self.minWidth)
        .background(MailTheme.Color.surface)
    }

    /// The narrowest the pane gets before the split view takes width from the
    /// other columns — enough for the 44pt insets and a readable body line.
    static let minWidth: CGFloat = 360

    private var content: some View {
        VStack(spacing: 0) {
            // The subject is available as soon as a thread is selected (it
            // comes off the conversation row); the sender block below it needs
            // the individual MESSAGE, which loads a moment later. Showing the
            // subject alone during that gap — rather than nothing at all — is
            // the same reasoning the pre-redesign code split ThreadHeader from
            // SelectedMessageHeader for. Siblings, never `.id()`-reset: the web
            // view is reused and only reloads when its rendered body changes.
            SelectedMessageHeader(
                message: model.selectedMessage,
                subject: ReadingPaneSender.subject(
                    selectedMessage: model.selectedMessage, conversation: model.selectedConversation
                ),
                position: ReadingPaneMessagePosition.resolve(
                    threadMessages: model.threadMessages,
                    selectedMessageID: model.selectedMessageID,
                    isShowingThread: model.isShowingThread
                ),
                labels: model.selectedMessageLabels,
                mailboxAddress: model.selectedMessage.map {
                    ReadingPaneMailboxAddress.resolve(
                        for: $0, mailboxes: model.monogramMailboxes, accountID: model.accountID,
                        tintName: model.accountTint?.name, in: model.observedDefaults
                    )
                }
            )
            Rectangle()
                .fill(MailTheme.Color.lineSoft)
                .frame(height: 1)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, MailTheme.Spacing.xl)
            MessageBodySection(model: model)
        }
    }

    /// The handoff's reading-pane edge inset (§3.1 "padding 32 44") — 44 is off
    /// the 4pt spacing grid (the scale tops out at `xxxl` 32), so this stays a
    /// named literal here rather than forcing a token that doesn't exist.
    fileprivate static let horizontalPadding: CGFloat = ReadingPaneEdgeAlignment.headerInset
}

/// "Nothing selected" — the handoff's empty state (§3.1; icon map "Empty:
/// nothing selected / no results" → `envelope.open`).
private struct ReadingPaneEmptyState: View {
    var body: some View {
        VStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: MailTheme.Symbol.nothingSelected)
                .font(MailTheme.Typography.largeGlyph)
                .foregroundStyle(MailTheme.Color.ink3)
            Text("Nothing selected")
                .textStyle(MailTheme.Typography.threadTitle)
                .foregroundStyle(MailTheme.Color.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing selected")
    }
}

/// Closes the gap between the header's own edge inset and the web view's
/// CSS body margin, so the header's and the message body's text line up on
/// the same left/right edge.
///
/// The header is inset 44pt in SwiftUI (``ReadingPaneView/horizontalPadding``,
/// the handoff's §3.1 edge inset). The web view can't share that: its body
/// text comes from the ONE shared CSS document every `WKWebView` in the app
/// loads (`MailViewModel+HTMLAssembly.swift`'s `styleSheet`), which sets a
/// 16px `margin` — and that stylesheet is also what the small signature-
/// preview box renders with, so raising it to 44px there would eat most of
/// that box's width. Insetting the web view's SwiftUI CONTAINER by the
/// difference instead reaches the same total inset (28pt SwiftUI + 16px CSS =
/// 44pt) without touching the shared document at all.
nonisolated enum ReadingPaneEdgeAlignment {
    /// The header's own edge inset (mirrors ``ReadingPaneView/horizontalPadding``).
    static let headerInset: CGFloat = 44
    /// The shared web document's CSS `body { margin: … }`. The ONE source: the
    /// stylesheet in `MailViewModel+HTMLAssembly.swift` interpolates this value
    /// (in whole px), so the two edges cannot drift apart.
    static let webContentCSSMargin: CGFloat = 16
    /// What's left to add in SwiftUI so the two text edges land on the same
    /// pixel. `max(0, …)`: if the CSS margin ever grew past the header inset,
    /// this stays a no-op rather than going negative and pulling the web view
    /// the WRONG way.
    static let webViewInset: CGFloat = max(0, headerInset - webContentCSSMargin)
}

/// Pure derivation of the reading pane's "Message N of M" line (handoff §3.1
/// "Thread view" — "The reading pane shows 'Message N of M' (N counts
/// oldest-first)"). Read-only over `MailViewModel`'s existing thread state
/// (`threadMessages` is already newest-first — see `MailViewModel.loadThread`),
/// so this never duplicates or reorders it.
///
/// `nil` whenever the pane is not showing a drilled-in thread at all — a
/// single-message conversation never enters `isShowingThread`, and the design
/// only shows the counter "when the message is part of a drilled-in thread".
nonisolated enum ReadingPaneMessagePosition {
    static func resolve(
        threadMessages: [MessageSummary],
        selectedMessageID: String?,
        isShowingThread: Bool
    ) -> (position: Int, total: Int)? {
        guard isShowingThread, let selectedMessageID,
              let newestFirstIndex = threadMessages.firstIndex(where: { $0.id == selectedMessageID })
        else { return nil }
        let total = threadMessages.count
        // `threadMessages` is newest-first (index 0 = newest = "M of M"), so the
        // oldest-first position is the count minus the newest-first index.
        return (position: total - newestFirstIndex, total: total)
    }

    static func label(_ value: (position: Int, total: Int)?) -> String? {
        guard let value else { return nil }
        return "Message \(value.position) of \(value.total)"
    }
}

/// Pure derivation of the reading pane's sender-block address chip: which
/// mailbox a message belongs to, with the domain badge that goes on it
/// (handoff §3.1 — "a 'To [badge] address' chip", "'From' for Drafts and
/// Sent"). Distinct from `message.to` (the recipient list): the chip names the
/// MAILBOX the message lives in, the same fact a conversation row's
/// row attribution shows in the wider scopes, not who else was copied.
nonisolated enum ReadingPaneMailboxAddress {
    struct Info: Equatable {
        let word: String
        let address: String
        let badge: DomainBadgeResolver.Info?
    }

    /// Drafts and Sent show "From" (it's the sending mailbox); everything else
    /// shows "To" (the receiving one). Pure and static so the rule is
    /// assertable without a rendered header.
    static func word(for folder: MailFolder) -> String {
        folder == .sent || folder == .drafts ? "From" : "To"
    }

    /// `tintName` is the account's OBSERVED tint (`MailViewModel.accountTint`),
    /// so the badge repaints when Settings changes it; `nil` falls back to
    /// reading the override from `defaults`.
    static func resolve(
        for message: MessageSummary,
        mailboxes: [Mailbox],
        accountID: String,
        tintName: String? = nil,
        in defaults: UserDefaults
    ) -> Info {
        let word = word(for: message.folder)
        // `mailboxID` is nil only for a catch-all message sync hasn't assigned
        // to a mailbox yet (see `MessageSummary.mailboxID`'s doc comment) — rare,
        // but it must still read as something rather than crash the lookup.
        guard let mailboxID = message.mailboxID,
              let mailbox = mailboxes.first(where: { $0.id == mailboxID })
        else {
            return Info(word: word, address: "No mailbox", badge: nil)
        }
        let badge = tintName.map {
            DomainBadgeResolver.resolve(
                mailboxID: mailboxID, mailboxes: mailboxes, accountID: accountID, tintName: $0, in: defaults
            )
        } ?? DomainBadgeResolver.resolve(
            mailboxID: mailboxID, mailboxes: mailboxes, accountID: accountID, in: defaults
        )
        return Info(word: word, address: mailbox.address, badge: badge)
    }
}

/// Pure derivation of the header's sender block and subject, so the parsing
/// that is easy to get wrong — a quoted "Last, First" display name, a bare
/// address, an older message of the thread being read — is assertable without
/// a rendered header. The sender helpers are the SAME ones the list rows use
/// (`ListColumn.senderName` / `.initials`), so a sender reads identically in
/// the list and in the pane.
nonisolated enum ReadingPaneSender {
    /// What the name line shows: `"Mara Okafor" <mara@acme.co>` → "Mara Okafor".
    static func name(_ fromAddress: String) -> String { ListColumn.senderName(fromAddress) }

    /// The avatar's two letters: "Weber, Jonas" → "WJ", ops@north.io → "OP".
    static func initials(_ fromAddress: String) -> String { ListColumn.initials(fromAddress) }

    /// The bare address, for the name's tooltip and the spoken value.
    static func address(_ fromAddress: String) -> String { ListColumn.bareAddress(fromAddress) }

    /// The address for the header's accessibility VALUE, or `nil` when the
    /// name line already IS the address (no display name) — said once, not twice.
    static func spokenAddress(_ fromAddress: String) -> String? {
        let bare = address(fromAddress)
        return bare.isEmpty || bare == name(fromAddress) ? nil : bare
    }

    /// The SELECTED message's subject once it has loaded — a reply deep in a
    /// thread can carry a different subject from the latest message — and the
    /// conversation row's until then, so the pane is never blank in between.
    static func subject(selectedMessage: MessageSummary?, conversation: ConversationSummary?) -> String {
        selectedMessage?.subject ?? conversation?.latest.subject ?? ""
    }
}

/// Labels for the MESSAGE being read.
///
/// Message-level, where the conversation list's menu is thread-level, and on
/// purpose: this pane shows exactly one message and draws that message's chips,
/// so the control beside them has to change the same thing they show. The server
/// keeps both — `PUT /messages/{id}/labels/{labelId}` and its conversation
/// sibling, which fans the change out over every accessible message of the thread.
///
/// Internal (not `private`): the window toolbar now hosts this menu too
/// (`RootView.toolbar`, handoff order "…archive, trash, labels…").
struct MessageLabelMenu: View {
    @Bindable var model: MailViewModel

    var body: some View {
        if !model.labels.isEmpty, let messageID = model.selectedMessageID {
            Menu {
                ForEach(model.labels) { label in
                    // Same rule as the list's menu: the getter reads the model, so an
                    // open menu shows the checkmark move.
                    Toggle(label.name, isOn: Binding(
                        get: { model.selectedMessageLabelIDs.contains(label.id) },
                        set: { newValue in
                            Task { await model.setLabel(label.id, onMessage: messageID, assigned: newValue) }
                        }
                    ))
                }
            } label: {
                Image(systemName: MailTheme.labelSymbol)
                    .frame(width: MailTheme.iconButtonSize.width, height: MailTheme.iconButtonSize.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // On the MENU, not on its label image: a `Menu`'s label view is not
            // the accessibility element (see the sidebar's account menu).
            .help("Labels")
            .accessibilityLabel("Labels")
        }
    }
}

/// Who the message being read is from and to, the subject and — inside a
/// drilled-in thread — "Message N of M". Static: picking WHICH message is the
/// middle column's job, so this is a header, not a control (every action that
/// used to live here now lives in the window toolbar).
///
/// `message` is `nil` for the moment between picking a thread and its message
/// loading (`MailViewModel.loadThread` is async): the subject still draws from
/// the conversation row, so the pane shows something immediately rather than
/// going blank, and the sender block — which needs the individual message —
/// fades in a beat later.
private struct SelectedMessageHeader: View {
    let message: MessageSummary?
    let subject: String
    let position: (position: Int, total: Int)?
    /// The labels on THIS message — not on its thread. The two differ: a
    /// conversation carries the union across its messages, and the reading pane
    /// is showing exactly one of them.
    var labels: [MailLabel] = []
    let mailboxAddress: ReadingPaneMailboxAddress.Info?

    /// Hoisted: building a `Date.FormatStyle` per render is pure waste.
    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// The neutral initials avatar (handoff §3.1). Unlike a thread row's
    /// own-message avatar (R5), this one is never account-tinted — it draws
    /// whoever sent THIS message, not "was this me".
    static let avatarDiameter: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xl) {
            if let position {
                Text(ReadingPaneMessagePosition.label(position) ?? "")
                    .textStyle(MailTheme.Typography.meta)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityHidden(true)
            }
            Text(subject.isEmpty ? "(No subject)" : subject)
                .textStyle(MailTheme.Typography.title)
                .foregroundStyle(MailTheme.Color.ink)
                .lineLimit(2)
            if let message, let mailboxAddress {
                HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
                    // Unread is a dot on the sender's name AND the bold weight
                    // below: never colour alone.
                    ZStack {
                        Circle().fill(MailTheme.Color.lineSoft)
                        Text(ReadingPaneSender.initials(message.fromAddress))
                            .textStyle(MailTheme.Typography.headline)
                            .foregroundStyle(MailTheme.Color.ink2)
                    }
                    .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                        HStack(spacing: MailTheme.Spacing.xs) {
                            Circle()
                                .fill(message.isUnread ? MailTheme.unreadIndicator : .clear)
                                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                                .accessibilityHidden(true)
                            // The display name, as the list row shows it; the
                            // bare address is the tooltip (and is spoken).
                            Text(ReadingPaneSender.name(message.fromAddress))
                                .textStyle(MailTheme.Typography.headline)
                                .foregroundStyle(MailTheme.Color.ink)
                                .lineLimit(1)
                                .help(ReadingPaneSender.address(message.fromAddress))
                        }
                        AddressChip(info: mailboxAddress)
                    }
                    Spacer()
                    Text(message.displayDate, format: Self.dateFormat)
                        .textStyle(MailTheme.Typography.meta)
                        .foregroundStyle(MailTheme.Color.ink3)
                }
                // Every label, not the list's first three: there is room here
                // and this is where the reader asks "what is this filed under".
                LabelChipRow(labels: labels, limit: labels.count)
            }
        }
        .padding(.horizontal, ReadingPaneView.horizontalPadding)
        .padding(.top, MailTheme.Spacing.xxxl)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            [
                ReadingPaneMessagePosition.label(position),
                message?.isUnread == true ? "Unread" : nil,
                message.flatMap { ReadingPaneSender.spokenAddress($0.fromAddress) },
                mailboxAddress.map { "\($0.word) \($0.address)" },
                LabelChipRow.accessibilityPhrase(for: labels),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}

/// The "To [badge] address" / "From [badge] address" chip (handoff §3.1).
private struct AddressChip: View {
    let info: ReadingPaneMailboxAddress.Info

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xs) {
            Text(info.word)
                .textStyle(MailTheme.Typography.snippet)
                .foregroundStyle(MailTheme.Color.ink2)
            HStack(spacing: MailTheme.Spacing.xs) {
                if let badge = info.badge, let tint = MailTheme.accountTint(named: badge.tintName) {
                    DomainBadge(monogram: badge.monogram, tint: tint, size: .row)
                }
                Text(info.address)
                    .textStyle(MailTheme.Typography.snippet)
                    .foregroundStyle(MailTheme.Color.ink)
                    .lineLimit(1)
            }
            .padding(.leading, info.badge == nil ? MailTheme.Spacing.sm : MailTheme.Spacing.xxs)
            .padding(.trailing, MailTheme.Spacing.sm)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(chipTint.opacity(MailTheme.Wash.chipFill), in: Capsule())
            .overlay(Capsule().strokeBorder(chipTint.opacity(MailTheme.Wash.chipBorder)))
        }
        // The chip is decorative next to the header's own combined
        // accessibility value (`SelectedMessageHeader.accessibilityValue`).
        .accessibilityHidden(true)
    }

    private var chipTint: Color {
        info.badge.flatMap { MailTheme.accountTint(named: $0.tintName) }?.solid ?? MailTheme.Color.line
    }
}

/// Internal rather than `private` so its banner strings — one source for what is
/// drawn and what VoiceOver announces — are assertable from the test target.
struct MessageBodySection: View {
    @Bindable var model: MailViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let body = model.body, body.offersRemoteConsent {
                BannerView(
                    systemImage: MailTheme.Symbol.remoteImages,
                    tint: .secondary,
                    text: Self.remoteConsentText(quotedHistoryOnly: body.remoteConsentIsForQuotedHistoryOnly)
                ) {
                    Button("Load Remote Images") { Task { await model.trustRemoteMedia() } }
                }
            }
            if let body = model.body {
                // Insets the web view to line its CSS-margined body text up
                // with the header's 44pt edge — see `ReadingPaneEdgeAlignment`.
                MessageWebView(body: body)
                    .padding(.horizontal, ReadingPaneEdgeAlignment.webViewInset)
            } else if model.isLoadingBody {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if model.inlineImagesUnavailable > 0 {
                BannerView(
                    systemImage: "photo.badge.exclamationmark",
                    tint: .secondary,
                    text: Self.inlineImageFailureText(count: model.inlineImagesUnavailable)
                ) { EmptyView() }
            }
            if let attachments = model.detail?.downloadableAttachments, !attachments.isEmpty {
                Divider()
                AttachmentBar(model: model, attachments: attachments)
            }
        }
        // Both banners appear underneath the message, after the reader has moved
        // on — silently, until now. They are announced when they arrive (and only
        // then: the `onChange` fires on the transition, so re-reading the same
        // message does not repeat them).
        .onChange(of: activeRemoteConsentText) { _, text in announce(text) }
        .onChange(of: activeInlineFailureText) { _, text in announce(text) }
    }

    /// The consent banner's text while it is showing, `nil` while it is not.
    private var activeRemoteConsentText: String? {
        guard let body = model.body, body.offersRemoteConsent else { return nil }
        return Self.remoteConsentText(quotedHistoryOnly: body.remoteConsentIsForQuotedHistoryOnly)
    }

    private var activeInlineFailureText: String? {
        guard model.inlineImagesUnavailable > 0 else { return nil }
        return Self.inlineImageFailureText(count: model.inlineImagesUnavailable)
    }

    private func announce(_ text: String?) {
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Banner strings as pure statics: one source for what is drawn and what is
    /// announced, and assertable without a rendered pane.
    nonisolated static func remoteConsentText(quotedHistoryOnly: Bool) -> String {
        quotedHistoryOnly
            ? "Remote images in this message's quoted history were blocked."
            : "Remote images in this message were blocked."
    }

    nonisolated static func inlineImageFailureText(count: Int) -> String {
        count == 1
            ? "An image embedded in this message could not be loaded."
            : "\(count) images embedded in this message could not be loaded."
    }
}

private struct AttachmentBar: View {
    @Bindable var model: MailViewModel
    let attachments: [Attachment]

    /// The file Quick Look is showing. Set on the way in, cleared by the panel.
    @State private var previewURL: URL?
    /// The attachment whose staged file the open Quick Look panel is holding.
    @State private var pinnedPreviewID: String?
    /// Attachments whose download Quick Look is waiting on, so each chip can say
    /// so instead of looking like a click that did nothing.
    @State private var loadingIDs: Set<String> = []

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MailTheme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    chip(for: attachment)
                }
            }
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.vertical, MailTheme.Spacing.sm)
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, url in
            if url == nil { releasePin() }
        }
        // Selecting another message must close a panel showing the old message's
        // file, and must not leave its pin behind.
        .onChange(of: attachments.map(\.id)) { _, _ in
            previewURL = nil
            releasePin()
        }
        .onDisappear {
            previewURL = nil
            releasePin()
        }
    }

    private func chip(for attachment: Attachment) -> some View {
        AttachmentChip(
            filename: attachment.filename,
            sizeBytes: attachment.sizeBytes,
            isInFlight: loadingIDs.contains(attachment.id)
        ) {
            HStack(spacing: MailTheme.Spacing.xxs) {
                Button { preview(attachment) } label: {
                    Image(systemName: MailTheme.Symbol.quickLook)
                        .iconButtonStyle("Quick Look \(attachment.filename)")
                }
                .buttonStyle(.plain)

                Button {
                    Task { await model.saveAttachment(attachment) }
                } label: {
                    Image(systemName: MailTheme.Symbol.download)
                        .iconButtonStyle("Save \(attachment.filename)…")
                }
                .buttonStyle(.plain)
            }
        }
        // Dragging the chip drags the FILE: the provider downloads only when the
        // drop target actually asks for the bytes, so a stray drag costs nothing.
        .onDrag { AttachmentDrag.itemProvider(for: attachment, api: model.api) }
    }

    /// Downloads (once) and hands the file to Quick Look.
    private func preview(_ attachment: Attachment) {
        guard loadingIDs.insert(attachment.id).inserted else { return }
        Task {
            defer { loadingIDs.remove(attachment.id) }
            do {
                // Pinned inside the actor, in the same step that stages it.
                let url = try await AttachmentFile.shared.url(for: attachment, using: model.api, pinned: true)
                // The user may have moved to another message while this
                // downloaded; opening Quick Look on the previous message's file
                // would be a panel they never asked for. `attachments` is the
                // CURRENT list — the closure captured the old view value before,
                // so the check passed for a message no longer on screen.
                guard model.detail?.downloadableAttachments.contains(where: { $0.id == attachment.id }) == true
                else { return }
                // The pin is held for as long as the panel shows the file and
                // released in `previewURL`'s change handler. The hand-over of
                // `pinnedPreviewID` happens with NO await in between, so a
                // concurrent `releasePin()` cannot drop the same pin twice.
                let previous = pinnedPreviewID
                pinnedPreviewID = attachment.id
                previewURL = url
                if let previous { await AttachmentFile.shared.unpin(previous) }
            } catch {
                model.actionError = error.localizedDescription
            }
        }
    }

    /// Drops the pin when Quick Look closes (it writes `nil` back through the
    /// binding) or when the preview moves to another attachment.
    private func releasePin() {
        guard let pinned = pinnedPreviewID else { return }
        pinnedPreviewID = nil
        Task { await AttachmentFile.shared.unpin(pinned) }
    }
}
