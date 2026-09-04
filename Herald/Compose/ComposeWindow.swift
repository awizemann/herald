import AppKit
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
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fields
            Divider()
            TextEditor(text: $model.bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(MailTheme.Spacing.sm)
                .frame(minHeight: 200)
                .accessibilityLabel("Message body")
            if let quotedPreview = model.quotedPreview { quotedPreviewSection(quotedPreview) }
            if model.showsSignaturePicker { signatureSection }
            if !model.attachments.isEmpty || !model.pendingUploads.isEmpty { attachmentBar }
            if let message = model.status.message { errorBar(message) }
        }
        // The WHOLE window is the drop target, not just the attachment bar: a bar
        // that only exists once there is an attachment cannot receive the first one.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.drop(urls) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                    .strokeBorder(Color.accentColor, lineWidth: MailTheme.selectionBorderWidth * 2)
                    .padding(MailTheme.Spacing.xs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Keyed on the From address: it can arrive after the first layout, and a
        // bare `.task` would then leave the window without a picker for good.
        .task(id: model.draft.fromAddress) { await model.loadSignatures() }
        .navigationTitle(model.windowTitle)
        .background(closeShortcut)
        .background(pasteShortcut)
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
        if model.isClosed { return true }
        let hasUnsaved = model.hasUnsavedChanges
        model.requestClose()
        return !hasUnsaved
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
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
                // A bare spinner is an unlabelled "busy" element: VoiceOver said
                // "progress indicator" and nothing about what the window is doing.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.busyDescription)
            }
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
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
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
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

    /// Read-only, collapsed-by-default preview of the quoted original the
    /// server will append below the authored text on send. Display only: it is
    /// never written into `model.bodyText` — the server appends its own copy
    /// on `POST /reply`/`POST /forward`, so folding it into the draft would
    /// double the quoted history.
    private func quotedPreviewSection(_ text: String) -> some View {
        DisclosureGroup("Quoted \(model.draft.mode.forwardOfMessageID != nil ? "message" : "original")") {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MailTheme.Spacing.sm)
            }
            .frame(maxHeight: 160)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
        .accessibilityLabel("Quoted original message, included automatically when you send")
    }

    /// Signature picker plus a read-only preview of what the server will append.
    ///
    /// Display only, exactly like ``quotedPreviewSection``: the server assembles
    /// authored text + signature + quoted original itself, so writing the preview
    /// into `model.bodyText` would send the signature twice.
    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
            if let preview = model.signaturePreview {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MailTheme.Spacing.sm)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
                    .accessibilityLabel("Signature preview, added automatically when you send")
            }
            Menu {
                // Toggle rows, exactly like `LabelMenu`/`MessageLabelMenu`: the
                // checkmark a `Toggle` draws is also EXPOSED (VoiceOver says
                // "selected"), where the old hand-drawn `Label(systemImage:)`
                // check was visual only — and its empty-string symbol on the
                // unselected rows was undefined behaviour.
                //
                // Still a Menu of rows rather than a Picker, for the original
                // reason: a Picker cannot disable a single row, and the draft's
                // saved copy of a deleted signature MUST be unpickable — asking
                // for it again is a 400 `SIGNATURE_NOT_AVAILABLE`.
                ForEach(model.signatureOptions) { option in
                    // The getter reads the model, never a value snapshotted at
                    // body-evaluation time, so an open menu shows the checkmark move.
                    Toggle(option.label, isOn: Binding(
                        get: { model.signatureTag == option.id },
                        set: { isOn in if isOn { model.signatureTag = option.id } }
                    ))
                    .disabled(!option.isSelectable)
                }
            } label: {
                Text(model.signatureMenuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Label only, NO `.accessibilityValue`: a pop-up button's value is
            // already its label view (the current signature), so spelling the
            // same string into the value made VoiceOver say it twice. The
            // modifier goes on the MENU, not on its label view — a Menu's label
            // is not the accessibility element (see `MessageLabelMenu`).
            .accessibilityLabel("Signature")
            .disabled(model.isBusy)
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: MailTheme.Spacing.sm) {
                ForEach(model.attachments) { attachment in
                    AttachmentChip(filename: attachment.filename, sizeBytes: attachment.sizeBytes) {
                        Button { Task { await model.removeAttachment(attachment) } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .iconButtonStyle("Remove \(attachment.filename)")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(model.pendingUploads) { pending in
                    AttachmentChip(
                        filename: pending.filename,
                        sizeBytes: pending.byteCount,
                        isInFlight: true
                    ) {
                        Button { model.cancelUpload(pending.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .iconButtonStyle("Cancel uploading \(pending.filename)")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.vertical, MailTheme.Spacing.sm)
        }
        .accessibilityLabel("Attachments")
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MailTheme.failure)
            Text(message).font(.callout)
            Spacer()
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
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

    /// ⌘V attaches files and images from the pasteboard — and, when there are
    /// none, hands the paste straight back to whatever text view has focus.
    /// Binding the shortcut takes it away from the responder chain, so forwarding
    /// is not a nicety: without it, pasting text into the body would stop working.
    private var pasteShortcut: some View {
        Button("Paste") {
            let contents = PasteboardReader.contents()
            Task {
                if await model.paste(contents) == false {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
        }
        .keyboardShortcut("v", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// A left-aligned label column so the fields line up like Mail's.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MailTheme.Spacing.sm) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            content
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
    }
}
