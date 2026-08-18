import HeraldKit
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
                SelectedMessageHeader(message: message)
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
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.md)
    }
}

/// Who the message being read is from and to. Static: picking WHICH message is
/// the middle column's job, so this is a header, not a control.
private struct SelectedMessageHeader: View {
    let message: MessageSummary

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
            }
            Spacer()
            Text(message.displayDate, format: Self.dateFormat)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
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
            HStack(spacing: MailTheme.Spacing.sm) {
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
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.vertical, MailTheme.Spacing.sm)
        }
    }
}
