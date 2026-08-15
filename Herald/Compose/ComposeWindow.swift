import HeraldKit
import SwiftUI

/// The compose scene: one NSWindow per draft, keyed by the request id that
/// opened it so `openWindow(value:)` can address it.
struct ComposeScene: Scene {
    let environment: AppEnvironment

    var body: some Scene {
        WindowGroup("New Message", for: ComposeRequest.ID.self) { $requestID in
            ComposeWindowRoot(requestID: requestID)
                .environment(environment)
        }
        .defaultSize(width: 680, height: 520)
        .commandsRemoved()
    }
}

/// Resolves the request id into a view-model, or explains why it cannot.
private struct ComposeWindowRoot: View {
    @Environment(AppEnvironment.self) private var environment
    let requestID: ComposeRequest.ID?
    @State private var model: ComposeViewModel?

    var body: some View {
        Group {
            if let model {
                ComposeView(model: model)
            } else {
                ContentUnavailableView(
                    "This draft is no longer available",
                    systemImage: "square.and.pencil",
                    description: Text("Start a new message from the File menu.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .task(id: requestID) {
            guard let requestID else { return }
            model = environment.makeComposeViewModel(id: requestID)
        }
    }
}

/// The compose form. Tab order is to → cc → bcc → subject → body → Send, which
/// is what Full Keyboard Access walks.
struct ComposeView: View {
    @Bindable var model: ComposeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fields
            Divider()
            TextEditor(text: $model.bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .accessibilityLabel("Message body")
            if !model.attachments.isEmpty { attachmentBar }
            if let message = model.status.message { errorBar(message) }
        }
        .navigationTitle(model.windowTitle)
        .background(closeShortcut)
        .onChange(of: model.isClosed) { _, closed in
            if closed { dismiss() }
        }
        .onDisappear { model.stop() }
        .confirmationDialog(
            "Save this message as a draft?",
            isPresented: $model.confirmsClose,
            titleVisibility: .visible
        ) {
            Button("Save Draft") { Task { await model.saveAndClose() } }
            Button("Delete Draft", role: .destructive) { Task { await model.discard() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your message has changes that have not been saved.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Button { Task { await model.send() } } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.isBusy)
            .help("Send")

            Button { Task { await model.addAttachments() } } label: {
                Image(systemName: "paperclip")
                    .iconButtonStyle("Attach File")
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)

            Button { Task { await model.discard() } } label: {
                Image(systemName: "trash")
                    .iconButtonStyle("Delete Draft")
            }
            .buttonStyle(.borderless)

            Spacer()

            if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            addressField("To", text: $model.toText, field: .to)
            Divider()
            addressField("Cc", text: $model.ccText, field: .cc)
            Divider()
            addressField("Bcc", text: $model.bccText, field: .bcc)
            Divider()
            LabeledField(label: "Subject") {
                TextField("Subject", text: $model.subject)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Subject")
            }
        }
    }

    private func addressField(
        _ label: String,
        text: Binding<String>,
        field: ComposeViewModel.Field
    ) -> some View {
        LabeledField(label: label) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(label, text: text)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(label)
                if let hint = model.hint(for: field) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(MailTheme.failure)
                        .accessibilityLabel("\(label) field: \(hint)")
                }
            }
        }
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(attachment.filename).lineLimit(1)
                        Button { Task { await model.removeAttachment(attachment) } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .iconButtonStyle("Remove \(attachment.filename)")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Attachments")
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MailTheme.failure)
            Text(message).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    /// ⌘W has to route through the view-model so unsaved work gets a sheet
    /// instead of vanishing; Escape is deliberately not bound to anything.
    private var closeShortcut: some View {
        Button("Close") { model.requestClose() }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// A left-aligned label column so the fields line up like Mail's.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
