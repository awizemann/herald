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
            ThreadHeader(model: model)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.selectedConversation?.latest.subject.isEmpty == false
                ? model.selectedConversation!.latest.subject
                : "(No subject)")
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
                    MessageHeaderRow(message: message, isSelected: message.id == model.selectedMessageID)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedMessageID = message.id }
                    Divider()
                }
            }
        }
        .frame(maxHeight: model.threadMessages.count > 1 ? 160 : 76)
    }
}

private struct MessageHeaderRow: View {
    let message: MessageSummary
    let isSelected: Bool

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
            Text(message.displayDate, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                    HStack(spacing: 6) {
                        Image(systemName: "doc").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename).font(.caption).lineLimit(1)
                            Text(
                                attachment.sizeBytes.formatted(
                                    .byteCount(style: .file)
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await model.saveAttachment(attachment) }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .iconButtonStyle("Save \(attachment.filename)…")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
