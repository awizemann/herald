import HeraldKit
import SwiftUI

/// Detail pane: the selected thread, with the selected message expanded.
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
            Divider()
            // The picker and the body are siblings, never `.id()`-reset: the web
            // view is reused and only reloads when its rendered body changes.
            ThreadMessageList(model: model)
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
            Button { Task { await model.performOnSelection(.archive) } } label: {
                Image(systemName: "archivebox")
                    .iconButtonStyle("Archive")
            }
            .buttonStyle(.plain)
            Button { Task { await model.performOnSelection(.trash) } } label: {
                Image(systemName: "trash")
                    .iconButtonStyle("Move to Trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Every message in the thread; picking one loads it below.
private struct ThreadMessageList: View {
    @Bindable var model: MailViewModel

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.threadMessages) { message in
                    // A Button, not a tap gesture: a gesture is invisible to
                    // Full Keyboard Access, VoiceOver and Switch Control, so the
                    // messages in a thread could only be picked with a mouse.
                    Button {
                        model.selectedMessageID = message.id
                    } label: {
                        MessageHeaderRow(message: message, isSelected: message.id == model.selectedMessageID)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: model.threadMessages.count > 1 ? 160 : 76)
        // Arrowing through the thread, the way the conversation list works.
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let messages = model.threadMessages
        guard messages.count > 1,
              let current = messages.firstIndex(where: { $0.id == model.selectedMessageID })
        else { return .ignored }
        let next = current + offset
        guard messages.indices.contains(next) else { return .handled }
        model.selectedMessageID = messages[next].id
        return .handled
    }
}

private struct MessageHeaderRow: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let message: MessageSummary
    let isSelected: Bool

    /// Hoisted: building a `Date.FormatStyle` per row per render is pure waste in
    /// a list that re-renders on every selection change.
    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isUnread ? MailTheme.unreadIndicator : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.fromAddress)
                    .font(.subheadline)
                    .fontWeight(message.isUnread ? .bold : .semibold)
                Text("To: \(message.to.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(message.displayDate, format: Self.dateFormat)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? MailTheme.selectionHighlight : .clear)
        // A 12% tint is the ONLY selection signal here; when the user has asked
        // for shape as well as colour it needs an outline too.
        .overlay {
            if isSelected && differentiateWithoutColor {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: MailTheme.selectionBorderWidth)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(message.isUnread ? "Unread" : "")
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
                    text: "Remote images in this message were blocked."
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

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(filename: attachment.filename, sizeBytes: attachment.sizeBytes) {
                        Button {
                            Task { await model.saveAttachment(attachment) }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .iconButtonStyle("Save \(attachment.filename)…")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
