import AppKit
import HeraldKit
import QuickLook
import SwiftUI

/// The compose scene: one NSWindow per draft, keyed by the request id that
/// opened it so `openWindow(value:)` can address it.
struct ComposeScene: Scene {
    let environment: AppEnvironment

    var body: some Scene {
        WindowGroup("New Message", for: ComposeRequest.ID.self) { $requestID in
            ComposeWindowRoot(requestID: requestID)
                .environment(environment)
                #if DEBUG
                // UI-test mode's throwaway defaults, like the other scenes.
                .defaultAppStorage(UITestHarness.launched?.defaults ?? .standard)
                #endif
        }
        .defaultSize(MailTheme.composeWindow)
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
                ComposeView(model: model) { mailboxID in
                    requestID.flatMap { environment.composeFromBadge(requestID: $0, mailboxID: mailboxID) }
                }
            } else {
                ContentUnavailableView(
                    "This draft is no longer available",
                    systemImage: "square.and.pencil",
                    description: Text("Start a new message from the File menu.")
                )
            }
        }
        .frame(minWidth: MailTheme.composeWindow.width, minHeight: MailTheme.composeWindow.height)
        .background(MailTheme.Color.surface)
        .task(id: requestID) {
            guard let requestID else { return }
            // Idempotent: this task re-runs whenever SwiftUI rebuilds the scene
            // root, and it must find the SAME composer, with whatever the user
            // has typed into it, rather than build a second one.
            //
            // Never swaps a live composer for `nil`: a composer whose account
            // was signed out has no session any more, but its window still owns
            // the text the user is about to copy out of it.
            let resolved = environment.makeComposeViewModel(id: requestID)
            if resolved != nil || model?.isClosed != false { model = resolved }
        }
        .onDisappear {
            guard let requestID, let model else { return }
            // The local attachment copies go with the window (Quick Look and
            // Download on compose cards are a this-window-session affordance).
            model.releaseLocalFiles()
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
    /// Optional on purpose: the non-optional form TRAPS when the value is absent,
    /// and this view is also built in previews and tests that have no
    /// `AppEnvironment`. Only the signature-refresh key reads it, and `nil` there
    /// just means "never invalidated from Settings".
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @State private var isDropTarget = false
    /// The compose card Quick Look is showing (a local copy; see `localFile`).
    @State private var attachmentPreviewURL: URL?
    @State private var attachmentsHeight: CGFloat = 0

    /// The From badge for a mailbox id (monogram + account tint).
    var fromBadge: (String) -> DomainBadgeResolver.Info? = { _ in nil }
    @FocusState private var focus: ComposeFocus?

    var body: some View {
        VStack(spacing: 0) {
            header
            fields
                .padding(.horizontal, MailTheme.Spacing.xxl)
            bodySection
            if let message = model.status.message { errorBar(message) }
            footer
        }
        .background(MailTheme.Color.surface)
        .ignoresSafeArea(.container, edges: .top)
        .background(ComposeWindowChrome())
        // The band draws the title and its own fill; the (empty) toolbar only
        // sizes the titlebar to 52pt so the traffic lights sit centred in it.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Pending recipient text is committed when its field loses focus.
        .onChange(of: focus) { old, _ in
            if let field = old?.recipientField { model.commitPending(field) }
        }
        // The WHOLE window is the drop target, not just the attachment bar: a bar
        // that only exists once there is an attachment cannot receive the first one.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.drop(urls) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                    .strokeBorder(MailTheme.Color.accent, lineWidth: MailTheme.selectionBorderWidth * 2)
                    .padding(MailTheme.Spacing.xs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Keyed on the From address: it can arrive after the first layout, and a
        // bare `.task` would then leave the window without a picker for good.
        // Also keyed on the signature revision, which Settings ▸ Signatures bumps
        // after every mutation — an already-open composer would otherwise keep
        // offering a signature that was just renamed or deleted.
        .task(id: SignatureFetchKey(
            fromAddress: model.draft.fromAddress,
            revision: environment?.signatureRevision ?? 0
        )) { await model.loadSignatures() }
        .navigationTitle(model.windowTitle)
        .background(closeShortcut)
        .background(pasteShortcut)
        .background(sendShortcut)
        .background(WindowCloseInterceptor(shouldClose: closeRequested))
        .onChange(of: model.isClosed) { _, closed in
            if closed { dismiss() }
        }
        // Keyed on the COUNTER, not the string: a held Send pressed twice
        // announces the same sentence twice, and an `onChange` on the string
        // would speak it once and then stay silent.
        .onChange(of: model.announcementCount) { _, _ in
            guard let message = model.announcement else { return }
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

    /// The 52pt toolbar band: traffic lights (window chrome), serif title,
    /// save status, Attach, Discard, Send. Drags the window.
    private var header: some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            Text(model.windowTitle)
                .textStyle(MailTheme.Typography.windowTitle)
                .foregroundStyle(MailTheme.Color.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: MailTheme.Spacing.md)

            if model.isBusy {
                // A bare spinner is an unlabelled "busy" element: VoiceOver said
                // "progress indicator" and nothing about what the window is doing.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.busyDescription)
                    .accessibilityIdentifier(AccessibilityID.Compose.busy)
            }
            if let caption = model.saveStatusCaption {
                Text(caption)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityIdentifier(AccessibilityID.Compose.saveStatus)
            }

            Button { Task { await model.addAttachments() } } label: {
                Image(systemName: MailTheme.Symbol.attachment)
                    .iconButtonStyle("Attach File")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.Compose.attach)
            .disabled(model.isBusy)

            Button { Task { await model.discard() } } label: {
                Image(systemName: MailTheme.Symbol.trash)
                    .iconButtonStyle("Delete Draft")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.Compose.deleteDraft)

            sendButton
        }
        .padding(.leading, MailTheme.Compose.trafficLightInset)
        .padding(.trailing, MailTheme.Spacing.lg)
        .frame(height: MailTheme.Compose.bandHeight)
        .background(MailTheme.Color.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MailTheme.Color.lineSoft).frame(height: 1)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var sendButton: some View {
        Button { Task { await model.send() } } label: {
            HStack(spacing: MailTheme.Spacing.sm - MailTheme.Spacing.xxs) {
                Image(systemName: MailTheme.Symbol.send)
                Text("Send").textStyle(MailTheme.Typography.bodyMedium)
                Text("⌘↩")
                    .textStyle(MailTheme.Typography.meta)
                    .opacity(MailTheme.Compose.shortcutHintOpacity)
            }
            .foregroundStyle(MailTheme.Color.onAccent)
            .padding(.horizontal, MailTheme.Spacing.md)
            .frame(height: MailTheme.Compose.sendHeight)
            .background(MailTheme.Color.accent, in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(SendButtonStyle())
        // Disabled until there is at least one valid recipient and no invalid
        // one (`isSendEnabled`, which also covers a send hold / signed-out
        // account). The footer says why.
        .disabled(model.isBusy || !model.isSendEnabled)
        // Both say the SAME sentence, and it is the hold's own reason rather
        // than the verb. The shortcuts are NOT here — see `sendShortcut`.
        .help(model.sendHelp)
        .accessibilityLabel("Send")
        .accessibilityHint(model.sendHoldReason ?? model.validationMessage ?? "")
        .accessibilityIdentifier(AccessibilityID.Compose.send)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            if !model.fromCandidates.isEmpty {
                ComposeFieldRow(label: "From") {
                    ComposeFromField(model: model, badge: fromBadge)
                }
            }
            ComposeFieldRow(label: "To") {
                HStack(alignment: .top, spacing: MailTheme.Spacing.sm) {
                    RecipientTokenField(model: model, field: .to, label: "To", identifier: AccessibilityID.Compose.to, focus: $focus)
                    if !model.showsCcBcc {
                        Button("Cc Bcc") {
                            model.showsCcBcc = true
                            focus = .cc
                        }
                        .buttonStyle(.plain)
                        .textStyle(MailTheme.Typography.fieldLabel)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .frame(height: MailTheme.Compose.rowHeight)
                        .help("Show the Cc and Bcc fields")
                        .accessibilityLabel("Show Cc and Bcc")
                        .accessibilityIdentifier(AccessibilityID.Compose.ccBccToggle)
                    }
                }
            }
            if model.showsCcBcc {
                ComposeFieldRow(label: "Cc") {
                    RecipientTokenField(model: model, field: .cc, label: "Cc", identifier: AccessibilityID.Compose.cc, focus: $focus)
                }
                ComposeFieldRow(label: "Bcc") {
                    RecipientTokenField(model: model, field: .bcc, label: "Bcc", identifier: AccessibilityID.Compose.bcc, focus: $focus)
                }
            }
            ComposeFieldRow(label: "Subject", height: MailTheme.Compose.subjectRowHeight) {
                TextField("Subject", text: $model.subject, prompt: Text("Subject").foregroundStyle(MailTheme.Color.ink3))
                    .textFieldStyle(.plain)
                    .font(MailTheme.Typography.composeSubject.font)
                    .foregroundStyle(MailTheme.Color.ink)
                    // The serif's tall ascender is clipped by the field
                    // editor's default single-line height (live finding).
                    .frame(minHeight: MailTheme.Compose.tokenHeight + MailTheme.Spacing.xs)
                    .focused($focus, equals: .subject)
                    .accessibilityLabel("Subject")
                    .accessibilityIdentifier(AccessibilityID.Compose.subject)
            }
        }
    }

    /// Body, signature block, quoted preview and attachment cards, inset to
    /// line up with the field values (padding 18 24 0 98, max width 600).
    private var bodySection: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.md) {
            TextEditor(text: $model.bodyText)
                .textStyle(MailTheme.Typography.reading)
                .foregroundStyle(MailTheme.Color.ink)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .frame(minHeight: 120)
                .accessibilityLabel("Message body")
                .accessibilityIdentifier(AccessibilityID.Compose.body)
            if let preview = model.signaturePreview { signatureBlock(preview) }
            if let quotedPreview = model.quotedPreview { quotedPreviewSection(quotedPreview) }
            if !model.attachments.isEmpty || !model.pendingUploads.isEmpty { attachmentBar }
        }
        .frame(maxWidth: MailTheme.Compose.bodyMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, MailTheme.Compose.bodyTop)
        .padding(.leading, MailTheme.Compose.bodyLeading - MailTheme.Spacing.xs)
        .padding(.trailing, MailTheme.Spacing.xxl)
        .padding(.bottom, MailTheme.Spacing.md)
    }

    /// Read-only preview of the signature the SERVER appends: "—", then its
    /// lines in 13 ink2. Display only — never written into `bodyText`, the
    /// server would send it twice.
    private func signatureBlock(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
            Text("—")
            Text(preview)
                .lineLimit(6)
                .textSelection(.enabled)
        }
        .textStyle(MailTheme.Typography.body)
        .foregroundStyle(MailTheme.Color.ink2)
        .padding(.leading, MailTheme.Spacing.xs + 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signature preview, added automatically when you send: \(preview)")
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
                    .textStyle(MailTheme.Typography.snippet)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MailTheme.Spacing.sm)
            }
            .frame(maxHeight: 160)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        }
        .accessibilityLabel("Quoted original message, included automatically when you send")
    }

    /// The 40pt footer: signature picker + scope caption on the left, inline
    /// validation on the right.
    private var footer: some View {
        HStack(spacing: MailTheme.Spacing.md) {
            if model.showsSignaturePicker {
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
                HStack(spacing: MailTheme.Spacing.xs + MailTheme.Spacing.xxs) {
                    Image(systemName: MailTheme.Symbol.signature)
                    Text(model.signatureCaption?.name ?? model.signatureMenuLabel)
                    Image(systemName: MailTheme.Symbol.folderMenu)
                        .font(MailTheme.Typography.inlineGlyph)
                        .foregroundStyle(MailTheme.Color.ink3)
                }
                .foregroundStyle(MailTheme.Color.ink2)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.Compose.signature)
            // Label only, NO `.accessibilityValue`: a pop-up button's value is
            // already its label view (the current signature), so spelling the
            // same string into the value made VoiceOver say it twice. The
            // modifier goes on the MENU, not on its label view — a Menu's label
            // is not the accessibility element (see `MessageLabelMenu`).
            .accessibilityLabel("Signature")
            .disabled(model.isBusy)
                if let caption = model.signatureCaption {
                    Text(caption.scope)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MailTheme.Spacing.md)
            if let message = model.validationMessage {
                HStack(spacing: MailTheme.Spacing.xs + MailTheme.Spacing.xxs) {
                    Image(systemName: MailTheme.Symbol.warning)
                        .foregroundStyle(MailTheme.Color.warn)
                        .accessibilityHidden(true)
                    Text(message)
                        .foregroundStyle(MailTheme.Color.ink)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Compose.validation)
            }
        }
        .textStyle(MailTheme.Typography.fieldLabel)
        .padding(.horizontal, MailTheme.Spacing.xxl)
        .frame(height: MailTheme.Compose.footerHeight)
        .background(MailTheme.Color.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(MailTheme.Color.lineSoft).frame(height: 1)
        }
    }

    /// Two rows of cards before the section scrolls instead of eating the body.
    private static let maxAttachmentsHeight = AttachmentCard.height * 2 + MailTheme.Spacing.sm * 3

    private var attachmentBar: some View {
        // Sized to its cards up to two rows, then scrolls (measured: a
        // ScrollView otherwise takes every point it is offered).
        ScrollView(.vertical) {
            attachmentCards.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { attachmentsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(attachmentsHeight, AttachmentCard.height), Self.maxAttachmentsHeight))
        .quickLookPreview($attachmentPreviewURL)
        // A card removed while Quick Look shows it must not leave the panel on
        // a file that is about to be deleted.
        .onChange(of: model.attachments.map(\.id)) { _, _ in
            if let url = attachmentPreviewURL, !model.attachments.contains(where: { model.localFile(for: $0) == url }) {
                attachmentPreviewURL = nil
            }
        }
        .accessibilityLabel("Attachments")
    }

    private var attachmentCards: some View {
            AttachmentFlowLayout(spacing: MailTheme.Spacing.sm, maxItemWidth: AttachmentCard.maxWidth) {
                ForEach(model.attachments) { attachment in
                    let local = model.localFile(for: attachment)
                    AttachmentCard(
                        filename: attachment.filename,
                        contentType: attachment.contentType,
                        sizeBytes: attachment.sizeBytes,
                        // Only with a local copy (a file attached in THIS window):
                        // the API has no GET for a draft's attachment.
                        onQuickLook: local.map { url in { attachmentPreviewURL = url } },
                        onDownload: local.map { _ in { Task { await model.saveLocalAttachment(attachment) } } },
                        onRemove: { Task { await model.removeAttachment(attachment) } }
                    )
                }
                ForEach(model.pendingUploads) { pending in
                    AttachmentCard(
                        filename: pending.filename,
                        sizeBytes: pending.byteCount,
                        isInFlight: true,
                        onCancel: { model.cancelUpload(pending.id) }
                    )
                }
            }
            .padding(.vertical, MailTheme.Spacing.xxs)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: MailTheme.Spacing.sm) {
            // The message is ONE element; the Sign In button is its own, so
            // VoiceOver can reach and press it (a `.combine` over both would
            // fold the button into the sentence).
            HStack(spacing: MailTheme.Spacing.sm) {
                Image(systemName: MailTheme.Symbol.warning).foregroundStyle(MailTheme.failure)
                VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                    Text(message).textStyle(MailTheme.Typography.snippet)
                    // Why the last sign-in for this account failed (audit W5);
                    // only while Sign In is offered.
                    if let reason = model.signInFailureReason {
                        Text(reason)
                            .textStyle(MailTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(reason)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Compose.errorMessage)
            Spacer()
            signInControl
        }
        .padding(.horizontal, MailTheme.Spacing.md)
        .padding(.vertical, MailTheme.Spacing.sm)
        .background(.bar)
    }

    /// A dead session's way back in, for the account THIS message belongs to.
    /// After it succeeds the bar clears and the user presses Send again —
    /// nothing is resent automatically.
    @ViewBuilder private var signInControl: some View {
        switch model.signInAffordance {
        case .none:
            EmptyView()
        case .available:
            Button("Sign In") { Task { await model.signIn() } }
                .help("Sign in to this message’s account again")
                .accessibilityHint("Opens the sign-in window. Your message stays here; press Send again afterwards.")
                .accessibilityIdentifier(AccessibilityID.Compose.errorSignIn)
        case .inProgress:
            HStack(spacing: MailTheme.Spacing.xs) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Signing in…").textStyle(MailTheme.Typography.snippet).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Signing in to this message’s account")
            .accessibilityIdentifier(AccessibilityID.Compose.errorSigningIn)
        }
    }

    /// ⌘W has to route through the view-model so unsaved work gets a sheet
    /// instead of vanishing; Escape is deliberately not bound to anything.
    private var closeShortcut: some View {
        Button("Close") { _ = closeRequested() }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// ⌘⇧D lives here, not on the Send button, because SwiftUI withdraws a
    /// DISABLED control's key equivalent along with the control: once a 503 held
    /// the send, pressing ⌘⇧D did nothing at all — no send (right) and no
    /// explanation (wrong). This proxy is never disabled by the hold, so the
    /// shortcut always reaches ``ComposeViewModel/send()``, which refuses and
    /// re-announces the reason. `isBusy` still disables it: a send already in
    /// flight is a different thing from one the server has forbidden.
    private var sendShortcut: some View {
        ZStack {
            Button("Send") { Task { await model.send() } }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Send") { Task { await model.send() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .disabled(model.isBusy)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// ⌘V attaches files and images from the pasteboard — and, when there are
    /// none, hands the paste straight back to whatever text view has focus.
    /// Binding the shortcut takes it away from the responder chain, so forwarding
    /// is not a nicety: without it, pasting text into the body would stop working.
    private var pasteShortcut: some View {
        Button("Paste") {
            // Text pasted into a recipient field splits into tokens.
            if let field = focus?.recipientField,
               let text = NSPasteboard.general.string(forType: .string),
               NSPasteboard.general.availableType(from: [.fileURL, .tiff, .png]) == nil {
                model.paste(text, into: field)
                ComposeFieldEditor.sync(to: model.pendingText(for: field))
                return
            }
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

/// The primary Send: exactly 45% when disabled (§3.3) — `.plain` would dim
/// it again on top — and a press darken.
private struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : MailTheme.Compose.disabledSendOpacity)
    }
}

/// What one signature-candidate fetch depends on.
///
/// A struct rather than a string built by interpolation: an address containing
/// the separator would otherwise be able to collide with a different
/// address/revision pair and silently skip a refetch.
nonisolated struct SignatureFetchKey: Hashable {
    let fromAddress: String
    let revision: Int
}
