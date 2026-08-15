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
        // NOT `.commandsRemoved()`: that also removes the scene from the Window
        // menu, so an open compose window could not be brought back with the
        // keyboard once it went behind the mail window.
        //
        // Drafts live on the server, so a relaunch re-fetches them; restoring the
        // scene would instead reopen a window whose request id resolves to
        // nothing and show "this draft is no longer available".
        .restorationBehavior(.disabled)
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
            // Idempotent: this task re-runs whenever SwiftUI rebuilds the scene
            // root, and it must find the SAME composer, with whatever the user
            // has typed into it, rather than build a second one.
            model = environment.makeComposeViewModel(id: requestID)
        }
        .onDisappear {
            guard let requestID, let model else { return }
            Task {
                // Flush before releasing: the window may be going away inside the
                // autosave debounce.
                await model.flushAndStop()
                environment.releaseComposeViewModel(id: requestID)
            }
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
        .background(WindowCloseInterceptor(shouldClose: closeRequested))
        .onChange(of: model.isClosed) { _, closed in
            if closed { dismiss() }
        }
        .onChange(of: model.announcement) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
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

    /// The single close rule, shared by ⌘W and the title-bar button. Returns
    /// whether the window may go: unsaved work turns into the sheet instead.
    private func closeRequested() -> Bool {
        let hasUnsaved = model.hasUnsavedChanges
        model.requestClose()
        return !hasUnsaved
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
        let hint = model.hint(for: field)
        return LabeledField(label: label) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(label, text: text)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(label)
                    // The hint belongs to the FIELD. As a sibling Text it was a
                    // separate element the user only met after leaving the field
                    // they had to go back and fix.
                    .accessibilityHint(hint ?? "")
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(MailTheme.failure)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    AttachmentChip(filename: attachment.filename) {
                        Button { Task { await model.removeAttachment(attachment) } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .iconButtonStyle("Remove \(attachment.filename)")
                        }
                        .buttonStyle(.borderless)
                    }
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
        Button("Close") { _ = closeRequested() }
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
