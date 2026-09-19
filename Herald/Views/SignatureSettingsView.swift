import HeraldKit
import SwiftUI
import WebKit

/// Settings ▸ Signatures — the manage-across-scopes list and its editor.
///
/// In its own file rather than inside `SettingsView`: the pane, its editor sheet
/// and the preview web view together are longer than the other three panes put
/// together.
struct SignatureSettingsPane: View {
    /// `let`, not `@State`: `AppEnvironment` owns one of these per account and
    /// keeps it. `@State` would have latched the FIRST account's model and gone
    /// on showing its signatures after a switch — which is what the
    /// `.id(selectedAccountID)` reset in `SettingsView` was papering over.
    let model: SignatureSettingsModel
    /// The re-auth action, for the "signed in before this existed" screen. `nil`
    /// in tests and previews, which hides the button rather than offering one
    /// that does nothing.
    var reauthenticate: (() -> Void)?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                SignatureMessagePane(
                    symbol: "hourglass",
                    title: "Loading signatures…",
                    message: nil
                ) {
                    ProgressView().controlSize(.small)
                }
            case .ready:
                if model.groups.isEmpty {
                    SignatureMessagePane(
                        symbol: "signature",
                        title: "No signatures yet",
                        message: "Signatures you can manage — your own, your mailboxes' and your domains' — appear here."
                    ) {
                        newSignatureButton
                    }
                } else {
                    signatureList
                }
            case .needsReauthorization:
                SignatureMessagePane(
                    symbol: "person.badge.key",
                    title: "Sign in again to manage signatures",
                    message: "This account was signed in before signature management existed — sign in again to manage signatures."
                ) {
                    if let reauthenticate {
                        Button("Sign In Again") {
                            // Recorded BEFORE the sign-in starts: if the new
                            // token still does not carry `signatures:manage`,
                            // the next load draws the terminal screen instead of
                            // offering this button again forever.
                            model.signInAgainRequested()
                            reauthenticate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .cannotManage:
                SignatureMessagePane(
                    symbol: "person.badge.key",
                    title: "This account cannot manage signatures",
                    message: "The server did not grant Herald permission to manage signatures for this account. Ask whoever administers it to grant the account signature management."
                ) {}
            case .unsupportedByServer:
                SignatureMessagePane(
                    symbol: "exclamationmark.triangle",
                    title: "Server too old",
                    message: "This server cannot manage signatures. It needs HQBase 1.4.2 or newer."
                ) {}
            case .failed(let message):
                SignatureMessagePane(
                    symbol: "exclamationmark.triangle",
                    title: "Signatures could not be loaded",
                    message: message
                ) {
                    Button("Try Again") { Task { await model.load() } }
                }
            }
        }
        // Keyed on the model's identity rather than reset with `.id(…)`: a new
        // account hands this pane a different model, and the load has to re-run
        // for it. A bare `.task` would keep showing the previous account's list.
        .task(id: ObjectIdentifier(model)) { await model.load() }
        .sheet(item: Bindable(model).editor) { editor in
            SignatureEditorSheet(model: model, editor: editor)
        }
        // Posted for the same reason every other Herald banner is: this one
        // appears at the top of a Form the cursor is not in, so VoiceOver would
        // otherwise never mention that the delete or the save failed.
        .onChange(of: model.announcementCount) { _, _ in
            guard let message = model.announcement else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .confirmationDialog(
            // `deletionPromptName`, not `pendingDeletion?.name`: confirming clears
            // `pendingDeletion` immediately, and SwiftUI re-reads the title while
            // the dialog is still animating out — which retitled it “Delete “”?”
            // in front of the user.
            "Delete “\(model.deletionPromptName)”?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmDeletion() } }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("Messages already sent keep the signature they were sent with.")
        }
    }

    private var signatureList: some View {
        Form {
            if let actionError = model.actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MailTheme.failure)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.signatures) { signature in
                        SignatureRow(model: model, signature: signature)
                    }
                } header: {
                    // Both parts are in the heading VoiceOver reads before the
                    // rows, so a "Work" signature is never ambiguous between two
                    // mailboxes that both have one.
                    Text("\(group.scope.displayName) · \(group.label)")
                }
            }
            Section {
                newSignatureButton
            }
        }
        .formStyle(.grouped)
    }

    private var newSignatureButton: some View {
        Button {
            model.beginCreate()
        } label: {
            Label("New Signature", systemImage: "plus")
        }
        // With no scope to file it under, creating one could only ever fail. The
        // hint says why rather than leaving a dead button.
        .disabled(model.scopeOptions.isEmpty)
        .accessibilityHint(
            model.scopeOptions.isEmpty
                ? "No mailbox or domain you can manage signatures for"
                : ""
        )
    }
}

/// The loading/empty/error screens, which differ only in symbol, words and the
/// action underneath.
private struct SignatureMessagePane<Action: View>: View {
    let symbol: String
    let title: String
    let message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: MailTheme.Spacing.md) {
            Image(systemName: symbol)
                .font(MailTheme.Typography.largeGlyph)
                .foregroundStyle(.secondary)
                // Decorative: the title below says the same thing in words.
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
        }
        .padding(MailTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.map { "\(title). \($0)" } ?? title)
    }
}

/// One signature: name, default badge, and its two actions.
private struct SignatureRow: View {
    let model: SignatureSettingsModel
    let signature: Signature

    var body: some View {
        HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                HStack(spacing: MailTheme.Spacing.sm) {
                    Text(signature.name)
                        .lineLimit(1)
                    if signature.isDefault { defaultBadge }
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: MailTheme.Spacing.sm) {
                Button("Edit") { model.beginEdit(signature) }
                Button {
                    model.pendingDeletion = signature
                } label: {
                    Image(systemName: "trash")
                }
                // An icon-only button is an unlabelled element to VoiceOver and
                // has no Voice Control name; both come from here.
                .accessibilityLabel("Delete \(signature.name)")
            }
            .fixedSize()
        }
        .padding(.vertical, MailTheme.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            signature.isDefault ? "\(signature.name), default" : signature.name
        )
    }

    /// The server's plain-text rendering, first line only — enough to tell two
    /// similarly named signatures apart without rendering HTML in a list row.
    private var preview: String {
        signature.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private var defaultBadge: some View {
        Text("Default")
            .font(.caption2)
            .padding(.horizontal, MailTheme.Spacing.sm)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(MailTheme.chipBackground, in: .rect(cornerRadius: MailTheme.Radius.sm))
            .foregroundStyle(MailTheme.chipLabelForeground)
            // Folded into the row's own label above, so VoiceOver says
            // "Work, default" instead of stopping on a stray chip.
            .accessibilityHidden(true)
    }
}

/// Create/edit. Name, scope (new signatures only), the HTML source and a live
/// rendering of it side by side, and the default toggle.
private struct SignatureEditorSheet: View {
    let model: SignatureSettingsModel
    @Bindable var editor: SignatureEditor
    /// The HTML the preview has actually rendered. Kept behind the field so the
    /// web view is not reloaded on every keystroke.
    @State private var previewHTML = ""
    /// Whether the preview has painted at all yet. The debounce is for KEYSTROKES;
    /// the first pass has nothing to debounce against and must paint at once.
    @State private var hasRenderedPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.lg) {
            Text(editor.title)
                .font(.headline)

            Form {
                TextField("Name", text: $editor.name)
                    .accessibilityLabel("Signature name")

                if editor.isEditingExisting {
                    // `PATCH /signatures/{id}` has no scope field, so this is
                    // stated rather than offered as a control that cannot work.
                    LabeledContent("Scope", value: scopeLabel)
                } else {
                    Picker("Scope", selection: $editor.scope) {
                        ForEach(model.scopeOptions) { option in
                            Text("\(option.scope.displayName) · \(option.label)")
                                .tag(SignatureScopeRef?.some(option.ref))
                        }
                    }
                }

                Toggle("Use as the default for this scope", isOn: $editor.isDefault)
            }
            .formStyle(.grouped)
            // `minHeight`, not `height`: at the larger accessibility text sizes
            // three fixed-120pt rows clipped the default toggle out of the sheet.
            .frame(minHeight: 120)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: MailTheme.Spacing.lg) {
                editorColumn(title: "HTML") {
                    TextEditor(text: $editor.html)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Signature HTML")
                        .overlay {
                            RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                                .strokeBorder(.separator)
                        }
                }
                editorColumn(title: "Preview") {
                    SignaturePreviewView(html: previewHTML)
                        .clipShape(.rect(cornerRadius: MailTheme.Radius.sm))
                        .overlay {
                            RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                                .strokeBorder(.separator)
                        }
                }
            }
            // 160, not 200: the editor is presented from a 640×420 Settings
            // window, and the sheet's natural height has to land inside it or
            // macOS clips the Save button off the bottom. It still grows.
            .frame(minHeight: 160)

            if let fieldError = editor.fieldError {
                Label(fieldError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(MailTheme.failure)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("The server sanitises and appends this signature when the message is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
            }
        }
        .padding(MailTheme.Spacing.xl)
        // A sheet cannot be bigger than the window it is presented from: at a
        // fixed 720×560 inside the 640×420 Settings window the editor was
        // clipped on both axes. Sized to FIT the host, and with `min`/`ideal`
        // bounds rather than a fixed frame so the sheet GROWS with the larger
        // accessibility text sizes instead of cutting the Save button off.
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
        // Debounced: re-rendering the web view on every keystroke would flicker
        // the preview and recompile nothing useful.
        .task(id: editor.html) {
            // Only a KEYSTROKE is debounced. The first pass has content the sheet
            // already holds, so sleeping here opened every Edit sheet onto 250ms
            // of blank preview.
            if hasRenderedPreview {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            previewHTML = editor.html
            hasRenderedPreview = true
        }
    }

    private var scopeLabel: String {
        guard let existing = editor.existing else { return "" }
        return "\(existing.scope.displayName) · \(existing.scopeLabel)"
    }

    private func editorColumn(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A read-only rendering of one signature's HTML.
///
/// Same containment posture as the reading pane (``MessageWebView``): JavaScript
/// off, a nil base URL, the compiled remote-content rule list in front of every
/// network load, and every navigation but our own refused via ``NavigationPolicy``.
/// Signature HTML is server-sanitised, but it is still markup this process did
/// not author, and a preview that phoned home would be a tracking pixel with a
/// different name.
struct SignaturePreviewView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.setAccessibilityLabel("Signature preview")
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, into: webView)
    }

    /// Closing the sheet mid-load left a Task holding the web view and waiting on
    /// the rule-list compile, which then touched a torn-down view.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    /// The preview document — the SAME one the reading pane builds for a message
    /// body.
    ///
    /// Not a lookalike: `MailViewModel.document(wrapping:)` is the shared emitter,
    /// so the preview carries the identical locked-down CSP meta (`default-src
    /// 'none'`, remote images blocked, no framing, no forms, no base-uri), the
    /// identical `MailTheme.Web` palette variables for light and dark, and the
    /// identical `@media (prefers-contrast: more)` overrides. A preview with its
    /// own inline styles told the user their signature looked like something it
    /// would never look like once sent — and quietly had no CSP at all.
    nonisolated static func document(for html: String) -> String {
        MailViewModel.document(
            wrapping: MailViewModel.composeBody(html: html),
            title: "Signature preview"
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// What was handed to WebKit, so an unrelated SwiftUI pass does not
        /// reload identical content and flash the pane.
        private var loaded: String?
        private var loadTask: Task<Void, Never>?
        /// Set immediately before `loadHTMLString` and consumed by the first
        /// main-frame decision, so exactly one navigation per render is ours.
        private var expectsOurLoad = false

        func load(_ html: String, into webView: WKWebView) {
            guard html != loaded else { return }
            loaded = html
            loadTask?.cancel()
            loadTask = Task { [weak webView] in
                let ruleList = await RemoteContentBlocker.ruleList()
                guard let webView, !Task.isCancelled else { return }
                guard let ruleList else {
                    // Without the blocker we refuse to render rather than render
                    // unprotected — the reading pane's rule. Nothing is claimed
                    // as loaded, so the next pass tries again.
                    //
                    // The rule list already installed is deliberately NOT removed
                    // first: dropping a known-good blocker before finding out
                    // whether a replacement exists leaves the view strictly less
                    // protected than it was a moment earlier.
                    self.loaded = nil
                    self.expectsOurLoad = true
                    webView.loadHTMLString(Self.blockerFailureDocument, baseURL: nil)
                    return
                }
                // Swapped only now that the replacement is in hand.
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(ruleList)
                self.expectsOurLoad = true
                webView.loadHTMLString(SignaturePreviewView.document(for: html), baseURL: nil)
            }
        }

        /// Ends any load in flight. Called from `dismantleNSView`.
        func cancel() {
            loadTask?.cancel()
            loadTask = nil
        }

        /// Nothing navigates out of a preview — not even a clicked link, which in
        /// the reading pane opens a browser but here would be a click on the
        /// user's own draft markup.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let decision = NavigationPolicy.decide(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                isOurInitialLoad: expectsOurLoad
            )
            guard decision == .allow else { return .cancel }
            expectsOurLoad = false
            return .allow
        }

        /// The failure screen goes through the shared emitter too. It is the
        /// document most likely to be rendered with NO rule list in front of it,
        /// so it is the one that can least afford to be the hand-rolled one
        /// without a CSP.
        nonisolated static let blockerFailureDocument = MailViewModel.document(
            wrappingPlainText: Coordinator.blockerFailureText,
            title: "Preview unavailable"
        )

        nonisolated static let blockerFailureText =
            "Herald could not start its content blocker, so this preview was not displayed."
    }
}
