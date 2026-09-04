import HeraldKit
// `.quickLookPreview` is a QuickLook-provided SwiftUI modifier, not a SwiftUI one.
import QuickLook
import SwiftUI

/// Detail pane: the ONE selected message, full height.
///
/// The in-pane list of every message in the thread is gone — picking a message
/// is the middle column's job now (see `ThreadMessageListView`), and keeping a
/// second copy here both duplicated the control and stole ~160pt from the body.
struct ReadingPaneView: View {
    @Bindable var model: MailViewModel

    var body: some View {
        Group {
            if model.selectedThreadID == nil {
                ContentUnavailableView("No Message Selected", systemImage: "envelope.open")
            } else {
                content
            }
        }
        .frame(minWidth: 360)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Only the subject goes in: the header used to take the whole
            // view-model and so re-rendered on every unrelated change to it.
            ThreadHeader(model: model, subject: model.selectedConversation?.latest.subject ?? "")
            // One header for the message being read, then the body. Siblings,
            // never `.id()`-reset: the web view is reused and only reloads when
            // its rendered body changes.
            if let message = model.selectedMessage {
                Divider()
                SelectedMessageHeader(message: message, labels: model.selectedMessageLabels)
            }
            Divider()
            MessageBodySection(model: model)
        }
    }
}

private struct ThreadHeader: View {
    @Bindable var model: MailViewModel
    let subject: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(subject.isEmpty ? "(No subject)" : subject)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Spacer()
            Button { model.requestCompose(.reply) } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .iconButtonStyle("Reply")
            }
            .buttonStyle(.plain)
            MessageLabelMenu(model: model)
            // Same rule as the toolbar's, from the same place: in the Trash this
            // header used to offer an Archive that the server ignored and a
            // Move to Trash that did nothing (issue #8).
            TriageButtons(model: model)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.md)
    }
}

/// Labels for the MESSAGE being read.
///
/// Message-level, where the conversation list's menu is thread-level, and on
/// purpose: this pane shows exactly one message and draws that message's chips,
/// so the control beside them has to change the same thing they show. The server
/// keeps both — `PUT /messages/{id}/labels/{labelId}` and its conversation
/// sibling, which fans the change out over every accessible message of the thread.
private struct MessageLabelMenu: View {
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
                    .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
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

/// Who the message being read is from and to. Static: picking WHICH message is
/// the middle column's job, so this is a header, not a control.
private struct SelectedMessageHeader: View {
    let message: MessageSummary
    /// The labels on THIS message — not on its thread. The two differ: a
    /// conversation carries the union across its messages, and the reading pane
    /// is showing exactly one of them.
    var labels: [MailLabel] = []

    /// Hoisted: building a `Date.FormatStyle` per render is pure waste.
    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
            // Unread is a dot AND the bold weight below: never colour alone.
            Circle()
                .fill(message.isUnread ? MailTheme.unreadIndicator : .clear)
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .padding(.top, MailTheme.Spacing.xs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                Text(message.fromAddress)
                    .font(.subheadline)
                    .fontWeight(message.isUnread ? .bold : .semibold)
                Text("To: \(message.to.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Every label, not the list's first three: there is room here and
                // this is where the reader asks "what is this filed under".
                LabelChipRow(labels: labels, limit: labels.count)
            }
            Spacer()
            Text(message.displayDate, format: Self.dateFormat)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            [message.isUnread ? "Unread" : nil, LabelChipRow.accessibilityPhrase(for: labels)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

private struct MessageBodySection: View {
    @Bindable var model: MailViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let body = model.body, body.offersRemoteConsent {
                BannerView(
                    systemImage: "photo",
                    tint: .secondary,
                    text: body.remoteConsentIsForQuotedHistoryOnly
                        ? "Remote images in this message's quoted history were blocked."
                        : "Remote images in this message were blocked."
                ) {
                    Button("Load Remote Images") { Task { await model.trustRemoteMedia() } }
                }
            }
            if let body = model.body {
                MessageWebView(body: body)
            } else if model.isLoadingBody {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if model.inlineImagesUnavailable > 0 {
                BannerView(
                    systemImage: "photo.badge.exclamationmark",
                    tint: .secondary,
                    text: model.inlineImagesUnavailable == 1
                        ? "An image embedded in this message could not be loaded."
                        : "\(model.inlineImagesUnavailable) images embedded in this message could not be loaded."
                ) { EmptyView() }
            }
            if let attachments = model.detail?.downloadableAttachments, !attachments.isEmpty {
                Divider()
                AttachmentBar(model: model, attachments: attachments)
            }
        }
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
                    Image(systemName: "eye")
                        .iconButtonStyle("Quick Look \(attachment.filename)")
                }
                .buttonStyle(.plain)

                Button {
                    Task { await model.saveAttachment(attachment) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
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
