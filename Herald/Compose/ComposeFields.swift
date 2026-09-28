import AppKit
import HeraldKit
import SwiftUI

/// What the compose form's keyboard focus can be on. Tab order is
/// to → cc → bcc → subject → body (Cc/Bcc only while shown).
enum ComposeFocus: Hashable {
    case to, cc, bcc, subject, body

    init(_ field: ComposeViewModel.Field) {
        switch field {
        case .to: self = .to
        case .cc: self = .cc
        case .bcc: self = .bcc
        }
    }

    var recipientField: ComposeViewModel.Field? {
        switch self {
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        case .subject, .body: nil
        }
    }
}

/// One header row: the 64pt right-aligned label column, then the value (§3.3).
struct ComposeFieldRow<Content: View>: View {
    let label: String
    var height: CGFloat = MailTheme.Compose.rowHeight
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: MailTheme.Spacing.md - MailTheme.Spacing.xxs) {
            Text(label)
                .textStyle(MailTheme.Typography.fieldLabel)
                .foregroundStyle(MailTheme.Color.ink3)
                .frame(width: MailTheme.Compose.labelColumn, alignment: .trailing)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MailTheme.Color.lineSoft).frame(height: 1)
        }
    }
}

// MARK: - From

/// The From field: badge, name, `local@` + domain, chevron — opening the
/// grouped, filterable address popover.
struct ComposeFromField: View {
    @Bindable var model: ComposeViewModel
    let badge: (String) -> DomainBadgeResolver.Info?
    @State private var isPicking = false

    var body: some View {
        Button { isPicking.toggle() } label: {
            HStack(spacing: MailTheme.Spacing.sm - MailTheme.Spacing.xxs) {
                if let from = model.selectedFrom {
                    FromBadge(info: badge(from.mailboxID))
                    if !from.displayName.isEmpty {
                        Text(from.displayName)
                            .textStyle(MailTheme.Typography.bodyMedium)
                            .foregroundStyle(MailTheme.Color.ink)
                    }
                    FromAddressText(address: from.address)
                } else {
                    FromAddressText(address: model.draft.fromAddress)
                }
                Image(systemName: MailTheme.Symbol.folderMenu)
                    .font(MailTheme.Typography.inlineGlyph)
                    .foregroundStyle(MailTheme.Color.ink3)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.fromCandidates.isEmpty || model.isBusy)
        .accessibilityLabel("From")
        .accessibilityValue(model.selectedFrom.map { "\($0.displayName) \($0.address)" } ?? model.draft.fromAddress)
        .accessibilityHint("Choose the address this message is sent from")
        .accessibilityIdentifier(AccessibilityID.Compose.from)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            FromPicker(model: model, badge: badge) { isPicking = false }
        }
    }
}

private struct FromBadge: View {
    let info: DomainBadgeResolver.Info?

    var body: some View {
        if let info, let tint = MailTheme.accountTint(named: info.tintName) {
            DomainBadge(monogram: info.monogram, tint: tint, size: .sidebar)
        }
    }
}

/// `local@` in ink2, the domain in ink3.
private struct FromAddressText: View {
    let address: String

    var body: some View {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        (Text(parts.count == 2 ? parts[0] + "@" : address).foregroundStyle(MailTheme.Color.ink2)
            + Text(parts.count == 2 ? parts[1] : "").foregroundStyle(MailTheme.Color.ink3))
            .textStyle(MailTheme.Typography.body)
    }
}

/// The From popover: a filter field, then addresses grouped by domain.
private struct FromPicker: View {
    @Bindable var model: ComposeViewModel
    let badge: (String) -> DomainBadgeResolver.Info?
    let dismiss: () -> Void
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(model.fromCandidates.count == 1 ? "Filter 1 address" : "Filter \(model.fromCandidates.count) addresses", text: $model.fromFilter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .padding(MailTheme.Spacing.sm)
                .accessibilityIdentifier(AccessibilityID.Compose.fromFilter)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.fromGroups) { group in
                        HStack(spacing: MailTheme.Spacing.sm - MailTheme.Spacing.xxs) {
                            FromBadge(info: group.candidates.first.flatMap { badge($0.mailboxID) })
                            Text(group.domain)
                                .textStyle(MailTheme.Typography.section)
                                .foregroundStyle(MailTheme.Color.ink3)
                        }
                        .padding(.horizontal, MailTheme.Spacing.md)
                        .padding(.top, MailTheme.Spacing.sm)
                        .padding(.bottom, MailTheme.Spacing.xs)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group.candidates) { candidate in
                            row(candidate)
                        }
                    }
                    if model.fromGroups.isEmpty {
                        Text("No matching addresses")
                            .textStyle(MailTheme.Typography.body)
                            .foregroundStyle(MailTheme.Color.ink3)
                            .padding(MailTheme.Spacing.md)
                    }
                }
                .padding(.bottom, MailTheme.Spacing.sm)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: MailTheme.Compose.fromPopoverWidth)
        .onAppear { filterFocused = true }
        .onDisappear { model.fromFilter = "" }
    }

    private func row(_ candidate: FromCandidate) -> some View {
        let isCurrent = candidate.id == model.selectedFrom?.id
        return Button {
            if model.selectFrom(candidate) || isCurrent { dismiss() }
        } label: {
            HStack(spacing: MailTheme.Spacing.sm) {
                Image(systemName: MailTheme.Symbol.currentItem)
                    .font(MailTheme.Typography.inlineGlyph)
                    .foregroundStyle(MailTheme.Color.accent)
                    .opacity(isCurrent ? 1 : 0)
                VStack(alignment: .leading, spacing: 0) {
                    if !candidate.displayName.isEmpty {
                        Text(candidate.displayName)
                            .textStyle(MailTheme.Typography.bodyMedium)
                            .foregroundStyle(MailTheme.Color.ink)
                    }
                    FromAddressText(address: candidate.address)
                }
                Spacer(minLength: MailTheme.Spacing.sm)
                if !candidate.canSend {
                    Text("Can't send")
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.vertical, MailTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(candidate.canSend ? 1 : MailTheme.Compose.unsendableOpacity)
        .disabled(!candidate.canSend)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(candidate.displayName.isEmpty ? "" : candidate.displayName + ", ")\(candidate.address)\(candidate.canSend ? "" : ", can't send")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Recipient tokens

/// A To/Cc/Bcc field: committed tokens flowing left to right, then the text
/// input for the next one. Pure SwiftUI (see the V6 plan: NSTokenField cannot
/// draw the avatar or the invalid style).
struct RecipientTokenField: View {
    @Bindable var model: ComposeViewModel
    let field: ComposeViewModel.Field
    let label: String
    let identifier: String
    var focus: FocusState<ComposeFocus?>.Binding
    /// The token the first Delete on an empty input selected; the second
    /// Delete removes it.
    @State private var selectedToken: Int?

    var body: some View {
        let tokens = model.tokens(for: field)
        TokenFlowLayout(spacing: MailTheme.Spacing.xs) {
            ForEach(tokens) { token in
                RecipientTokenChip(token: token, isSelected: selectedToken == token.index) {
                    selectedToken = nil
                    model.removeToken(at: token.index, in: field)
                }
                .onTapGesture {
                    selectedToken = token.index
                    focus.wrappedValue = ComposeFocus(field)
                }
            }
            TextField(
                tokens.isEmpty && field == .to ? "Name or address" : "",
                text: Binding(
                    get: { model.pendingText(for: field) },
                    set: { typed in
                        selectedToken = nil
                        // A menu or context-menu Paste lands here, not in the
                        // ⌘V proxy: when the split committed tokens, the field
                        // editor still shows the raw text. Pushed after the
                        // binding write finishes (the editor ignores a rewrite
                        // from inside its own edit).
                        if model.setPendingText(typed, for: field) {
                            // Captured now: by the time the Task runs focus may
                            // have moved (Tab), and the rewrite must not land in
                            // Subject or Body.
                            let editor = ComposeFieldEditor.current
                            Task { @MainActor in ComposeFieldEditor.sync(to: model.pendingText(for: field), in: editor) }
                        }
                    }
                )
            )
            .textFieldStyle(.plain)
            .textStyle(MailTheme.Typography.body)
            .frame(minWidth: 120)
            .focused(focus, equals: ComposeFocus(field))
            // Tab commits through the focus change (ComposeWindow's
            // `onChange(of: focus)`); the field editor consumes Tab before any
            // `.onKeyPress` would see it.
            .onSubmit { model.commitPending(field) }
            .accessibilityLabel(label)
            .accessibilityHint(model.hint(for: field) ?? "")
            .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, MailTheme.Spacing.xs + MailTheme.Spacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = ComposeFocus(field) }
        // Delete on an empty input, and the comma/semicolon commit: the text
        // field's field editor swallows keys before `.onKeyPress` sees them,
        // and a pending value rewritten from INSIDE the text binding's setter
        // is not pushed back into a field that is being edited (live: typing
        // "a@b.co," left "a@b.co," on screen after the token committed). So
        // both are caught at the window, before the field editor.
        .background(TokenKeyMonitor { key in
            guard focus.wrappedValue == ComposeFocus(field) else { return false }
            switch key {
            case .delete: return deleteOnEmpty()
            case .separator:
                selectedToken = nil
                model.commitPending(field)
                ComposeFieldEditor.sync(to: model.pendingText(for: field))
                return true
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// Delete on an empty input (``RecipientTokens/deleteAction``). Returns
    /// whether the key was used.
    private func deleteOnEmpty() -> Bool {
        switch RecipientTokens.deleteAction(
            pendingIsEmpty: model.pendingText(for: field).isEmpty,
            tokenCount: model.tokens(for: field).count,
            selected: selectedToken
        ) {
        case .ignore:
            return false
        case .select(let index):
            selectedToken = index
            return true
        case .remove(let index):
            selectedToken = nil
            model.removeToken(at: index, in: field)
            return true
        }
    }
}

/// The focused text field's field editor. A SwiftUI `TextField` that is
/// being edited does not pick up a new value written to its binding from
/// outside the keystroke that is editing it (live: after a comma commit the
/// field still showed the committed address), so a commit or paste that
/// rewrites the pending text pushes it into the editor directly.
enum ComposeFieldEditor {
    /// The key window's field editor, if a text field is being edited.
    static var current: NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    /// Rewrites `expected` (default: the current field editor) — and only if it
    /// is still the one being edited.
    static func sync(to text: String, in expected: NSTextView? = nil) {
        guard let editor = current, expected == nil || editor === expected,
              editor.string != text
        else { return }
        editor.string = text
    }
}

/// Calls `handler` for Delete (backspace) and the separator keys (`,` `;`)
/// pressed in THIS view's window; a `true` return consumes the event.
private struct TokenKeyMonitor: NSViewRepresentable {
    enum Key { case delete, separator }
    let handler: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.handler = handler
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var handler: (Key) -> Bool = { _ in false }
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .shift])
                guard flags.isEmpty else { return event }
                let key: Key
                if event.keyCode == 51, !event.modifierFlags.contains(.shift) {
                    key = .delete
                } else if let characters = event.characters, characters == "," || characters == ";" {
                    key = .separator
                } else {
                    return event
                }
                let windowNumber = event.windowNumber
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.view?.window, window.windowNumber == windowNumber else { return false }
                    return self.handler(key)
                }
                return used ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// One recipient: 22pt pill, 16pt initials avatar + name; the danger style
/// for an address that would not send.
struct RecipientTokenChip: View {
    let token: RecipientToken
    var isSelected = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xs) {
            ZStack {
                Circle().fill(token.isValid ? MailTheme.Color.lineSoft : MailTheme.Color.danger.opacity(MailTheme.Compose.invalidTokenFill))
                if token.isValid {
                    Text(ListColumn.initials(token.displayName.map { "\($0) <\(token.address)>" } ?? token.address))
                        .textStyle(MailTheme.Typography.tokenInitials)
                        .foregroundStyle(MailTheme.Color.ink2)
                } else {
                    Image(systemName: MailTheme.Symbol.invalidRecipient)
                        .font(MailTheme.Typography.inlineGlyph)
                        .foregroundStyle(MailTheme.Color.danger)
                }
            }
            .frame(width: MailTheme.Compose.tokenAvatar, height: MailTheme.Compose.tokenAvatar)
            Text(token.label)
                .textStyle(MailTheme.Typography.body)
                .foregroundStyle(token.isValid ? MailTheme.Color.ink : MailTheme.Color.danger)
                .lineLimit(1)
        }
        .padding(.leading, MailTheme.Spacing.xxs + 1)
        .padding(.trailing, MailTheme.Spacing.sm)
        .frame(height: MailTheme.Compose.tokenHeight)
        .background(
            token.isValid ? MailTheme.Color.bg : MailTheme.Color.danger.opacity(MailTheme.Compose.invalidTokenFill),
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(
                isSelected ? MailTheme.Color.accent
                    : token.isValid ? MailTheme.Color.line : MailTheme.Color.danger.opacity(MailTheme.Compose.invalidTokenRing),
                lineWidth: isSelected ? 2 : 1
            )
        }
        .help(token.address)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: token))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Remove", onRemove)
    }

    /// "Recipient, name, address[, invalid]".
    static func accessibilityLabel(for token: RecipientToken) -> String {
        var parts = ["Recipient"]
        if let name = token.displayName { parts.append(name) }
        parts.append(token.address)
        if !token.isValid { parts.append("invalid") }
        return parts.joined(separator: ", ")
    }
}

/// Left-to-right flow; the LAST subview (the text input) takes the rest of
/// its row, or a row of its own when less than its minimum is left.
struct TokenFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(width: proposal.width ?? 400, subviews: subviews)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let isInput = index == subviews.count - 1
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if isInput {
                let minimum = subview.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
                if x > 0, width - x < max(minimum, 120) {
                    x = 0; y += rowHeight + spacing; rowHeight = 0
                }
                size.width = width - x
            } else if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            rowHeight = max(rowHeight, MailTheme.Compose.tokenHeight, size.height)
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
        }
        // Centre each item vertically in its row height.
        return frames.map { frame in
            CGRect(x: frame.minX, y: frame.minY + max(0, (MailTheme.Compose.tokenHeight - frame.height) / 2),
                   width: frame.width, height: frame.height)
        }
    }
}

// MARK: - Window chrome

/// Gives the compose window its 52pt band: an empty unified toolbar (which
/// centres the traffic lights in a 52pt titlebar), hidden title text and a
/// transparent titlebar the SwiftUI band draws under.
struct ComposeWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.onWindow = { window in Self.apply(to: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func apply(to window: NSWindow) {
        // SwiftUI may already have installed a toolbar; any toolbar gives the
        // unified 52pt titlebar, so only add one when there is none.
        if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "compose.band") }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
    }

    private final class ChromeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
