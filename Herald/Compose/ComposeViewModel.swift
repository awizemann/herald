import AppKit
import Foundation
import HeraldKit
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "Compose")

/// One compose window's state: the draft, the text the user is typing into the
/// address fields, autosave and the send/discard verbs.
///
/// The heavy work (drafts, uploads, sending) all lives behind ``Outboxing`` —
/// an actor in production — so nothing here blocks the main actor beyond the
/// first suspension point.
@MainActor
@Observable
final class ComposeViewModel {
    enum Status: Equatable {
        case idle
        case saving
        case sending
        case failed(String)

        var message: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Which address field an error belongs to, so the hint sits under it.
    enum Field: Hashable { case to, cc, bcc }

    // MARK: Editable state

    var toText: String { didSet { commitRecipients(); edited(oldValue != toText) } }
    var ccText: String { didSet { commitRecipients(); edited(oldValue != ccText) } }
    var bccText: String { didSet { commitRecipients(); edited(oldValue != bccText) } }
    var subject: String {
        didSet {
            draft.subject = subject
            edited(oldValue != subject)
        }
    }
    var bodyText: String {
        didSet {
            draft.body = bodyText
            edited(oldValue != bodyText)
        }
    }

    // MARK: Derived / published state

    private(set) var draft: ComposeDraft
    /// Read-only preview of the quoted original the server will append below
    /// the authored text on send. `nil` for a new message or a reopened draft.
    /// DISPLAY ONLY — never concatenated into ``bodyText``/``draft/body``.
    let quotedPreview: String?
    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            // Any change of status retires the "sign in" classification of the
            // failure it replaces; ``fail(_:)`` re-raises it for a new one.
            requiresSignIn = false
            guard let message = status.message else { return }
            announce(message)
        }
    }

    // MARK: Dead session (2026-09-26 incident, plan P4)

    /// Whether the failure on the error bar is a dead session that only a fresh
    /// sign-in can fix — a send or autosave that came back 401 / refresh
    /// refused. Classified HERE, with the same rule the sync loop uses
    /// (``MailViewModel/requiresReauthentication(_:)``), so the view only asks
    /// "is there a Sign In button?".
    ///
    /// While it is set the failure is STICKY: typing neither clears it nor
    /// schedules an autosave. Every autosave would 401 against the same dead
    /// grant, re-raise the bar and re-announce it per debounce — and the text is
    /// safe in the window anyway. It clears when the account comes back
    /// (``accountSignedIn(outbox:)``) or when a send succeeds.
    private(set) var requiresSignIn = false

    /// What the error bar offers besides the message. Pure and static so the
    /// rule is assertable without a rendered window — `SyncStatusLabel`'s
    /// pattern.
    enum SignInAffordance: Equatable {
        case none
        /// A Sign In button.
        case available
        /// A sign-in for this account is already running (the banner's, the
        /// sidebar's, Herald's own automatic one, or this window's): the button
        /// becomes progress. A second click would only be refused by the policy.
        case inProgress
    }

    nonisolated static func signInAffordance(requiresSignIn: Bool, isSigningIn: Bool) -> SignInAffordance {
        guard requiresSignIn else { return .none }
        return isSigningIn ? .inProgress : .available
    }

    var signInAffordance: SignInAffordance {
        Self.signInAffordance(requiresSignIn: requiresSignIn, isSigningIn: isSigningIn)
    }

    /// Whether a re-auth round trip is running for THIS composer's account —
    /// read through the environment, so it tracks the one policy every entry
    /// point shares.
    var isSigningIn: Bool { isReauthenticating() }

    /// Why the last sign-in for this composer's account failed, shown under
    /// the error bar's message next to the Sign In button — only while that
    /// button is offered (``signInAffordance`` `.available`).
    var signInFailureReason: String? {
        guard signInAffordance == .available, let reason = reauthError() else { return nil }
        return Self.signInFailureDetail(reason)
    }

    nonisolated static func signInFailureDetail(_ reason: String) -> String {
        "The last sign-in didn’t work: \(reason)"
    }

    /// Set once this composer's account has been signed out (or replaced by a
    /// different user on re-auth). Its outbox belongs to a graph that is gone,
    /// so nothing is saved or sent from here any more — the window keeps the
    /// text so the user can copy it, and says why Send is unavailable. Never
    /// cleared: a later sign-in of the same origin is a NEW account graph this
    /// window was never bound to.
    private(set) var isAccountSignedOut = false

    nonisolated static let accountSignedOutReason =
        "This message’s account was signed out, so it can’t be sent. Copy anything you want to keep."
    /// What Save Draft says for such a composer: the draft cannot be kept on the
    /// server either.
    nonisolated static let accountSignedOutSaveReason =
        "This message’s account was signed out, so it can’t be saved as a draft. Copy anything you want to keep."

    /// Addresses that failed ``EmailAddress/isValid(_:)``, per field.
    private(set) var invalidAddresses: [Field: [String]] = [:]
    /// The message the error bar shows, announced when it appears. VoiceOver has
    /// no reason to visit the bottom of a compose window, so an error that is
    /// only drawn there is an error a blind user never learns about.
    private(set) var announcement: String?
    /// Bumped on EVERY announcement, including one that repeats the words already
    /// in ``announcement``. The window observes this rather than the string: a
    /// held Send pressed twice says the same sentence both times, and an
    /// `onChange` on the string alone would speak it once and then go silent —
    /// which is exactly the "⌘⇧D does nothing" the hold is supposed to explain.
    private(set) var announcementCount = 0

    /// Publishes a message for VoiceOver. Two calls inside one synchronous body
    /// coalesce into a single `onChange` delivery, so the belt-and-braces
    /// re-announce in ``send()`` cannot speak twice.
    private func announce(_ message: String) {
        announcement = message
        announcementCount += 1
    }

    /// Set when the window should go away: send succeeded, or the user discarded.
    private(set) var isClosed = false
    /// Non-nil once the server has told this window not to send again — the two
    /// 1.4.0 503s. While it is set, ``send()`` refuses and the Send button is
    /// disabled: the window stays open with every word in it, but Herald offers
    /// no retry, automatic or otherwise.
    ///
    /// The two holds differ in what the server did with the message, so they lift
    /// differently:
    ///
    /// - ``SendHold/recovering`` — the mail WAS accepted; a second copy is the
    ///   failure mode. The hold never lifts for this window. The user's recourse
    ///   is to close it once the message shows up in Sent.
    /// - ``SendHold/storageNotReady`` — nothing was accepted, the server simply
    ///   is not finished updating. Editing anything lifts the hold, so the user
    ///   can try again deliberately once they have reason to think it is over.
    ///   The send key is NOT rotated by that edit, so even a too-early retry
    ///   cannot deliver twice.
    private(set) var sendHold: SendHold?
    /// Whether Send is refused right now. The button reads this and so does
    /// ``send()`` — ⌘⇧D must not do what the disabled button will not.
    var isSendBlocked: Bool { sendHold != nil || isAccountSignedOut }

    /// Why Send is unavailable, or `nil` when it is not. The Send control drives
    /// BOTH its tooltip and its accessibility hint off this: a `.disabled` button
    /// whose only explanation is an error bar at the other end of the window
    /// announces "dimmed" and nothing else.
    var sendHoldReason: String? {
        isAccountSignedOut ? Self.accountSignedOutReason : Self.sendHoldReason(sendHold)
    }

    /// The Send control's tooltip for THIS window — ``sendHelp(_:)`` plus the
    /// signed-out case, so tooltip and hint still say the same sentence.
    var sendHelp: String { sendHoldReason ?? Self.sendHelp(nil) }

    /// Static and payload-free so the sentence the tooltip shows and the sentence
    /// VoiceOver speaks are provably the same one, assertable without a rendered
    /// window — the `ReauthBanner.message`/`announcement` pattern.
    nonisolated static func sendHoldReason(_ hold: SendHold?) -> String? {
        hold.map { OutboxError.sendOnHold($0).localizedDescription }
    }

    /// The Send control's tooltip: the verb when it works, the reason when it
    /// does not.
    ///
    /// The shortcut is spelled out because the button no longer carries the key
    /// equivalent itself (it lives on an always-enabled proxy, so a hold cannot
    /// withdraw it) and SwiftUI therefore no longer draws "⌘⇧D" in the tooltip.
    nonisolated static func sendHelp(_ hold: SendHold?) -> String {
        sendHoldReason(hold) ?? "Send (⌘⇧D)"
    }
    /// Drives the ⌘W confirmation sheet.
    var confirmsClose = false

    /// The account's CURRENT outbox. A `var` because re-authentication builds
    /// a new account graph: ``accountSignedIn(outbox:)`` moves a live composer
    /// onto it rather than leaving it talking to the superseded graph's client.
    /// Each operation reads it once, up front, so a call already in flight
    /// finishes on the outbox it started on.
    private var outbox: any Outboxing
    /// Bumped by every ``accountSignedIn(outbox:)``; see ``fail(_:binding:)``.
    @ObservationIgnored private var outboxBinding = 0
    /// Runs the re-auth round trip for this composer's OWN account (never the
    /// selected one — see `AppEnvironment.makeComposeViewModel`).
    @ObservationIgnored private let reauthenticate: @MainActor () async -> Void
    @ObservationIgnored private let isReauthenticating: @MainActor () -> Bool
    /// Why the last re-auth of this composer's account failed, if it did
    /// (`AppEnvironment.reauthErrors`, audit W5) — read through the
    /// environment, so a failure from the banner or the sidebar shows here too.
    @ObservationIgnored private let reauthError: @MainActor () -> String?
    private let autosaveDelay: Duration
    /// The draft as opened: what "the user has typed something" is measured against.
    private let initialDraft: ComposeDraft
    /// Where this window reports what it did to its server draft, so the Drafts
    /// folder reflects an autosave immediately instead of at the next poll.
    /// `@MainActor` because the view-model that consumes it is.
    private let draftCache: @MainActor @Sendable (DraftCacheEvent) -> Void
    /// Usage analytics, same seam as ``MailViewModel/record``: a closure, so a
    /// composer can neither flush nor read the opt-out. Default no-op.
    @ObservationIgnored private let record: @MainActor @Sendable (UsageEvent) -> Void
    /// Exposed so tests can await the debounce instead of sleeping on a wall clock.
    @ObservationIgnored private(set) var autosaveTask: Task<Void, Never>?
    /// Told each time a save is about to go to the outbox (``saveNow()`` past
    /// its guards) — whatever the outcome, and before the token provider can
    /// fail it fast. A seam like ``record``: the Debug UI-test harness counts
    /// these (`saveAttempts=`), because a save refused by a latched grant never
    /// reaches the server and so shows up in no server counter. Default no-op.
    @ObservationIgnored private let saveAttempted: @MainActor () -> Void

    init(
        context: ComposeContext,
        outbox: any Outboxing,
        autosaveDelay: Duration = .seconds(2),
        record: @escaping @MainActor @Sendable (UsageEvent) -> Void = { _ in },
        draftCache: @escaping @MainActor @Sendable (DraftCacheEvent) -> Void = { _ in },
        reauthenticate: @escaping @MainActor () async -> Void = {},
        isReauthenticating: @escaping @MainActor () -> Bool = { false },
        reauthError: @escaping @MainActor () -> String? = { nil },
        saveAttempted: @escaping @MainActor () -> Void = {}
    ) {
        let draft = context.makeDraft()
        self.draft = draft
        self.initialDraft = draft
        self.quotedPreview = context.quotedPreview
        self.outbox = outbox
        self.record = record
        self.autosaveDelay = autosaveDelay
        self.draftCache = draftCache
        self.reauthenticate = reauthenticate
        self.isReauthenticating = isReauthenticating
        self.reauthError = reauthError
        self.saveAttempted = saveAttempted
        self.toText = draft.to.joined(separator: ", ")
        self.ccText = draft.cc.joined(separator: ", ")
        self.bccText = draft.bcc.joined(separator: ", ")
        self.subject = draft.subject
        self.bodyText = draft.body
        // Reopening an existing draft takes ownership of it straight away: the
        // fence this raises is what stops a poll that is already in flight from
        // writing a pre-edit listing over the row under the user.
        if let existing = draft.serverDraft { draftCache(.saved(existing)) }
    }

    /// Reports the server's latest word on this draft to the Drafts folder.
    private func publishDraftState() {
        guard let saved = draft.serverDraft else { return }
        draftCache(.saved(saved))
    }

    // MARK: - Presentation

    var windowTitle: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Message" : trimmed
    }

    var attachments: [DraftAttachment] { draft.uploadedAttachments }

    /// Busy includes queued uploads: a batch that finishes its first file resets
    /// `status` to idle, and a Send button that re-enables there would send the
    /// message without the files still on their way up.
    var isBusy: Bool { status == .saving || status == .sending || !pendingUploads.isEmpty }

    /// What the header's spinner is for, in words — its accessibility label.
    /// Sending wins over the rest: it is the state the user is waiting on.
    var busyDescription: String {
        if status == .sending { return "Sending" }
        if !pendingUploads.isEmpty { return "Uploading attachments" }
        return "Saving draft"
    }

    /// Whether closing would lose work the server has not seen.
    var hasUnsavedChanges: Bool {
        // A sent or discarded composer owns nothing anymore: the programmatic
        // dismissal that follows `send()` still passes through windowShouldClose,
        // and must never turn into a "save or discard?" sheet (real-run finding).
        guard !isClosed, draft.isDirty else { return false }
        return draft.to != initialDraft.to
            || draft.cc != initialDraft.cc
            || draft.bcc != initialDraft.bcc
            || draft.subject != initialDraft.subject
            || draft.body != initialDraft.body
            || !draft.pendingAttachments.isEmpty
            || !pendingUploads.isEmpty
    }

    func invalid(_ field: Field) -> [String] { invalidAddresses[field] ?? [] }

    func hint(for field: Field) -> String? {
        let bad = invalid(field)
        guard !bad.isEmpty else { return nil }
        return bad.count == 1
            ? "“\(bad[0])” is not a valid email address."
            : "\(bad.count) addresses are not valid email addresses."
    }

    // MARK: - Signature

    /// One row of the signature picker.
    struct SignatureOption: Identifiable, Hashable {
        /// The picker tag: `"automatic"`, `"none"`, `"selected:<id>"`, or
        /// `"snapshot"` (the draft's saved copy of a signature that is gone).
        let id: String
        let label: String
        /// False for the draft's saved copy of a signature this address can no
        /// longer use — shown so the user knows what will be appended, but not
        /// selectable, because the server would answer `SIGNATURE_NOT_AVAILABLE`.
        let isSelectable: Bool
    }

    /// What `GET /signatures?from=…` said for this window's From address.
    private(set) var signatureCandidates: SignatureCandidates = .empty
    private(set) var signaturesLoaded = false

    /// Whether the picker has anything to offer. Hidden on a server that has no
    /// signatures route (404) or none defined for this address.
    var showsSignaturePicker: Bool {
        !signatureCandidates.signatures.isEmpty || draft.signatureSnapshot?.isEmpty == false
    }

    /// Read-only preview of the signature the SERVER will append below the
    /// authored text. DISPLAY ONLY — never concatenated into ``bodyText``, the
    /// same invariant as ``quotedPreview``.
    var signaturePreview: String? {
        if let candidate = signatureCandidates.resolved(draft.signature) {
            return candidate.text.isEmpty ? nil : candidate.text
        }
        guard let snapshot = draft.signatureSnapshot, !snapshot.isEmpty else { return nil }
        // The saved copy is the truth for a signature the list no longer carries,
        // and the only thing to show at all before the list has arrived.
        switch draft.signature {
        case .noSignature: return nil
        case .selected(let id): return snapshot.id == id ? snapshot.text : nil
        case .automatic: return signaturesLoaded ? nil : snapshot.text
        }
    }

    /// The picker's current tag. Setting it changes the selection and schedules a
    /// save, so the draft the server holds always matches what the window shows.
    ///
    /// `.automatic` gets its OWN row rather than being drawn as the signature it
    /// resolves to: re-picking that row would turn "follow the address's default"
    /// into a pin on today's default, silently and with nothing on screen to say
    /// so — and when the address has no default at all, drawing automatic as "No
    /// signature" would claim a decision the draft has not made.
    var signatureTag: String {
        get {
            switch draft.signature {
            case .noSignature: return "none"
            case .automatic: return "automatic"
            case .selected(let id): return "selected:\(id)"
            }
        }
        set { select(signatureTag: newValue) }
    }

    var signatureOptions: [SignatureOption] {
        var options = [SignatureOption(
            id: "automatic",
            label: signatureCandidates.resolved(.automatic).map { "Default · \($0.name)" }
                ?? (signaturesLoaded ? "Default · none set" : "Default"),
            isSelectable: true
        )]
        options += signatureCandidates.signatures.map { signature in
            SignatureOption(
                id: "selected:\(signature.id)",
                label: "\(signature.name) · \(Self.scopeLabel(of: signature))",
                isSelectable: true
            )
        }
        // The draft's own signature, when the list no longer carries it: shown so
        // the user can see what will be appended, unselectable because asking for
        // it again would be a 400. Only once the list has actually arrived — before
        // that, calling a perfectly good signature a "saved copy" is just wrong.
        let tag = signatureTag
        if signaturesLoaded, tag.hasPrefix("selected:"), !options.contains(where: { $0.id == tag }) {
            let name = draft.signatureSnapshot?.name ?? ""
            options.append(SignatureOption(
                id: tag,
                // The suffix is the REASON the row is disabled: a greyed-out row
                // with no explanation is invisible to VoiceOver, which announces
                // "dimmed" without ever saying why.
                label: name.isEmpty
                    ? "Saved signature (no longer available)"
                    : "\(name) · Saved copy (no longer available)",
                isSelectable: false
            ))
        }
        options.append(SignatureOption(id: "none", label: "No signature", isSelectable: true))
        return options
    }

    /// What the closed menu reads, and what VoiceOver reports as its value.
    var signatureMenuLabel: String {
        let tag = signatureTag
        return signatureOptions.first { $0.id == tag }?.label ?? "No signature"
    }

    private static func scopeLabel(of signature: Signature) -> String {
        switch signature.scope {
        case .user: return "Personal"
        case .mailbox: return signature.scopeLabel
        case .domain: return "Domain \(signature.scopeLabel)"
        }
    }

    private func select(signatureTag tag: String) {
        let selection: SignatureSelection
        if tag == "none" {
            selection = .noSignature
        } else if tag == "automatic" {
            selection = .automatic
        } else if tag.hasPrefix("selected:"), tag.count > "selected:".count {
            selection = .selected(id: String(tag.dropFirst("selected:".count)))
        } else {
            return // "snapshot": the saved copy is not selectable.
        }
        guard selection != draft.signature else { return }
        draft.signature = selection
        // Same path as any other edit: the debounced autosave persists the
        // selection, and a send before it lands saves first (`OutboxService.send`).
        edited(true)
    }

    /// Loads the signatures usable from this window's From address.
    ///
    /// Failures are silent by design: a server older than upstream 1.3.4 has no
    /// such route, and a compose window that cannot list signatures must still be
    /// able to send. `.automatic` then means "whatever the server decides", which
    /// is exactly right.
    ///
    /// Safe to call again — the view re-runs it if the From address arrives late.
    func loadSignatures() async {
        guard !draft.fromAddress.isEmpty, !isAccountSignedOut else { return }
        do {
            signatureCandidates = try await outbox.signatures(from: draft.fromAddress)
            signaturesLoaded = true
        } catch {
            logger.warning("Signatures unavailable: \(error.logCode, privacy: .public)")
        }
    }

    // MARK: - Recipients

    /// Splits on commas, semicolons and whitespace so paste-from-anywhere works.
    nonisolated static func parseAddresses(_ text: String) -> [String] {
        let parts = text.split { $0 == "," || $0 == ";" || $0.isWhitespace }
        return EmailAddress.dedupe(parts.map(String.init))
    }

    private func commitRecipients() {
        draft.to = Self.parseAddresses(toText)
        draft.cc = Self.parseAddresses(ccText)
        draft.bcc = Self.parseAddresses(bccText)
        invalidAddresses = [
            .to: draft.to.filter { !EmailAddress.isValid($0) },
            .cc: draft.cc.filter { !EmailAddress.isValid($0) },
            .bcc: draft.bcc.filter { !EmailAddress.isValid($0) },
        ].filter { !$0.value.isEmpty }
    }

    private var hasInvalidAddresses: Bool { !invalidAddresses.isEmpty }

    // MARK: - Autosave

    private func edited(_ changed: Bool) {
        guard changed else { return }
        // An edit is the user acting on "not yet": it lifts the recoverable hold
        // only. `.recovering` means a copy is already out, and no amount of
        // typing makes a second one right.
        if sendHold == .storageNotReady { sendHold = nil }
        // A dead session (or a signed-out account) is not something typing can
        // fix: the bar — and its Sign In button — stays, and no autosave is
        // queued to fail against it again.
        guard !requiresSignIn, !isAccountSignedOut else { return }
        if status.message != nil { status = .idle }
        scheduleAutosave()
    }

    /// Reports a failure on the error bar, classifying whether it is one only a
    /// fresh sign-in fixes. The one place a server error becomes `.failed`.
    ///
    /// - Parameter binding: ``outboxBinding`` when the failed call STARTED. A
    ///   dead-session answer from an outbox the composer has since been moved
    ///   off (a send already in flight when the re-auth landed) says nothing
    ///   about the new grant: it is shown, but offers no Sign In — the user
    ///   just presses Send again.
    private func fail(_ error: any Error, binding: Int) {
        status = .failed(error.localizedDescription)
        // After the assignment: `status`'s didSet resets the flag on a change.
        requiresSignIn = !isAccountSignedOut
            && binding == outboxBinding
            && MailViewModel.requiresReauthentication(error)
    }

    // MARK: - Sign in again

    /// The error bar's Sign In: re-runs consent for this composer's account.
    /// A no-op while one is already running — the policy would refuse a second
    /// window anyway, and the button is progress by then.
    func signIn() async {
        guard requiresSignIn, !isSigningIn else { return }
        announce("Signing in. Your message stays in this window.")
        await reauthenticate()
        // A success rebinds this composer (``accountSignedIn(outbox:)``), which
        // clears the failure and announces that. A failure leaves the bar up:
        // say why, once, here — the window's own attempt, so the user is
        // listening for its outcome. A Cancel records no reason and stays quiet.
        if requiresSignIn, !isSigningIn, let reason = reauthError() {
            announce("Sign-in didn’t work: \(reason)")
        }
    }

    /// The account this composer belongs to was signed in again and has a new
    /// graph: move onto its outbox and pick up where the dead session left off.
    ///
    /// Rebinding rather than closing (what install used to do) because the
    /// window keeps its view-model regardless: a closed session orphaned a
    /// composer still bound to the SUPERSEDED graph's API client, which only
    /// worked because that client's provider happens to re-read the Keychain —
    /// and a scene rebuild then found no session and replaced the half-written
    /// message with "no longer available".
    ///
    /// Nothing about the draft changes: its text, its server draft and its
    /// ``ComposeDraft/sendAttemptKey`` all live on the draft, not the outbox,
    /// so a Send after a 401 (which the server never accepted) retries under
    /// the same identity. The user presses Send again; nothing is resent here.
    func accountSignedIn(outbox: any Outboxing) {
        self.outbox = outbox
        outboxBinding += 1
        guard !isClosed, !isAccountSignedOut else { return }
        if requiresSignIn {
            status = .idle
            announce("Signed in again. Press Send to send your message.")
        }
        // Resume autosave for whatever was typed while it was paused. A save
        // still in flight on the OLD outbox is fine to overlap: a first-time
        // create there is waited out (``waitForDraftCreation()``), so this save
        // updates the draft it created rather than creating a second one. Not
        // during a send, which consumes the draft.
        if draft.isDirty, status != .sending { scheduleAutosave() }
    }

    /// The account this composer belongs to was signed out (or re-auth came back
    /// as a different user). Stops every timer and upload, and blocks Send for
    /// good with a reason: the window never sends or saves through an account
    /// that is gone. The text stays for the user to copy.
    func accountSignedOut() {
        stop()
        isAccountSignedOut = true
        guard !isClosed else { return }
        status = .failed(Self.accountSignedOutReason)
    }

    // MARK: - One server-draft create at a time

    /// Whether a call that may CREATE the server draft is in flight: a save or
    /// an upload started while the draft had no server id yet.
    ///
    /// `OutboxService` deduplicates concurrent creates, but only per INSTANCE,
    /// and a re-auth moves this composer onto a new graph's outbox
    /// (``accountSignedIn(outbox:)``). A create still in flight on the old one
    /// plus an edit after the rebind was two `POST /drafts` — a second server
    /// draft, the first orphaned. So the composer serializes its own: every
    /// later save or upload waits here (``waitForDraftCreation()``), then
    /// re-reads the draft, and by then it carries the server id the first call
    /// adopted and updates it instead. Waiting is structured (a continuation,
    /// not a task), so a caller's cancellation still reaches its own call.
    @ObservationIgnored private var isCreatingServerDraft = false
    @ObservationIgnored private var draftCreationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Test seam: how many calls are parked in ``waitForDraftCreation()``.
    var draftCreationWaiterCount: Int { draftCreationWaiters.count }

    /// Returns once no server-draft create is in flight. The caller must read
    /// ``draft`` AFTER this, with no suspension before its own outbox call.
    private func waitForDraftCreation() async {
        while isCreatingServerDraft {
            await withCheckedContinuation { draftCreationWaiters.append($0) }
        }
    }

    /// Claims the create slot when `sent` has no server draft; returns whether
    /// it did, for ``endDraftCreation(_:)``.
    private func beginDraftCreation(for sent: ComposeDraft) -> Bool {
        guard sent.serverDraft == nil else { return false }
        isCreatingServerDraft = true
        return true
    }

    /// Releases the slot — after the result has been ADOPTED into ``draft``,
    /// so a waiter sees the new server id — and wakes every waiter.
    private func endDraftCreation(_ claimed: Bool) {
        guard claimed else { return }
        isCreatingServerDraft = false
        let waiters = draftCreationWaiters
        draftCreationWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Debounced: every edit cancels the pending save, so a burst of typing
    /// costs one round trip rather than one per keystroke.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        isAutosavePending = true
        autosaveTask = Task { [autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
            } catch {
                return // Superseded by a later edit, or the window closed.
            }
            guard !Task.isCancelled else { return }
            self.isAutosavePending = false
            await self.saveNow()
        }
    }

    /// Drops the pending debounce, if any.
    private func cancelAutosave() {
        autosaveTask?.cancel()
        isAutosavePending = false
    }

    /// Whether a debounced autosave is scheduled and has not started saving.
    @ObservationIgnored private var isAutosavePending = false
    /// Saves whose `saveDraft` round trip has not come back yet.
    @ObservationIgnored private var savesInFlight = 0

    /// Test seam: whether a debounced autosave is waiting to run.
    var hasPendingAutosave: Bool { isAutosavePending }

    /// After a save lands: if the draft is STILL dirty and nothing else is
    /// going to save it, schedule one more (P9b, item J).
    ///
    /// The case: a re-auth rebinds the composer while a save is in flight on
    /// the OLD outbox, the user edits, and a save on the NEW outbox overlaps
    /// it. If the older one finishes last, the server holds its stale text and
    /// the draft is dirty against it — but the edit's own autosave has already
    /// run, so nothing was left to send the newer text again. Normally a dirty
    /// draft after a save means the user typed during the round trip, which
    /// already scheduled a save (`isAutosavePending`); another save still in
    /// flight will re-check when it lands. Never after a failure (a save that
    /// keeps failing must not turn into a retry loop) and never when an edit
    /// could not schedule one either (a dead session, a signed-out account, a
    /// send consuming the draft — including its waits before `.sending`).
    private func rescheduleAutosaveIfStillDirty() {
        // A pending attachment keeps the draft dirty after every save by
        // design (the upload queue delivers it, not a save): re-saving for it
        // would loop.
        guard draft.isDirty, draft.pendingAttachments.isEmpty, !isAutosavePending, savesInFlight == 0,
              !isClosed, !isAccountSignedOut, !requiresSignIn, status != .sending, !isSendInFlight
        else { return }
        scheduleAutosave()
    }

    /// Persists the draft if there is anything to persist. Never throws: an
    /// autosave failure is surfaced inline and the text stays in the window.
    func saveNow() async {
        guard isSaveWorthwhile else { return }
        // A create already in flight (possibly on the outbox this composer was
        // moved OFF by a re-auth) finishes first; re-checked after, because it
        // may have saved everything there was to save.
        await waitForDraftCreation()
        // Re-checked after the wait: the autosave that parked here may have
        // been cancelled meanwhile (a Send cancels it before waiting itself),
        // and a send in progress consumes the draft — a PATCH racing it would
        // only 404 onto the error bar.
        guard !Task.isCancelled, status != .sending, isSaveWorthwhile else { return }
        saveAttempted()
        status = .saving
        // The snapshot that goes to the server; the response is MERGED into
        // whatever the user has typed since, never assigned over it. Assigning
        // the response back reverted every keystroke made during the round trip,
        // and a server that normalises anything (trims a subject, rewrites the
        // body) left the draft dirty again — an autosave loop.
        let sent = draft
        let binding = outboxBinding
        let creating = beginDraftCreation(for: sent)
        defer { endDraftCreation(creating) }
        savesInFlight += 1
        do {
            let saved = try await outbox.saveDraft(sent)
            savesInFlight -= 1
            draft.adoptServerState(from: saved, sent: sent)
            // The cache learns about the draft the moment the server does, so the
            // Drafts folder shows what is being typed without waiting for a poll.
            publishDraftState()
            record(.draftSaved)
            if status == .saving { status = .idle }
            rescheduleAutosaveIfStillDirty()
        } catch {
            savesInFlight -= 1
            logger.warning("Draft autosave failed: \(error.logCode, privacy: .public)")
            fail(error, binding: binding)
        }
    }

    private var isSaveWorthwhile: Bool {
        guard !isClosed, !isAccountSignedOut, draft.isDirty, !hasInvalidAddresses else { return false }
        return !draft.to.isEmpty || !draft.subject.isEmpty || !draft.body.isEmpty
    }

    /// Saves a pending edit and then stops the timer, for the window actually
    /// going away.
    ///
    /// `stop()` alone cancels the debounce, so closing the window inside the
    /// autosave delay — which is most closes, since the last thing the user does
    /// is type — threw away everything typed since the previous save.
    func flushAndStop() async {
        cancelAutosave()
        autosaveTask = nil
        // Whatever else happens, the window is going away: the poll must get its
        // draft back or it could never tombstone that row again.
        defer { if let id = draft.serverDraft?.id { draftCache(.closed(id)) } }
        guard !isClosed, draft.isDirty else { return }
        await saveNow()
        // "Stop": a save that landed still dirty may have queued another; the
        // window is going away and this flush was the last word.
        cancelAutosave()
    }

    /// Test seam and window-close hook: waits for a pending debounce to finish.
    func waitForAutosave() async {
        await autosaveTask?.value
    }

    // MARK: - Send / discard

    /// Validates locally first, so an obviously bad address never costs a round
    /// trip and the error lands on the field instead of in an alert.
    @discardableResult
    func send() async -> Bool {
        // Before anything suspends (P9b, item J): the waits below come BEFORE
        // `status = .sending`, so a double click (or ⌘⇧D pressed twice) during
        // a pending upload or draft create started a second send of the same
        // message behind the first.
        guard !isSendInFlight else { return false }
        guard !isSendBlocked else {
            // Reached only by ⌘⇧D while the button is disabled — which is why the
            // shortcut lives on an always-enabled proxy in `ComposeWindow`:
            // SwiftUI withdraws a disabled control's key equivalent, so the user
            // pressed ⌘⇧D, nothing happened, and nothing said why.
            if let reason = sendHoldReason {
                // `status` may already BE this failure, and its `didSet` only
                // announces on a change, so the re-announcement is posted
                // explicitly. Every press says why.
                status = .failed(reason)
                announce(reason)
            }
            return false
        }
        isSendInFlight = true
        defer { isSendInFlight = false }
        cancelAutosave()
        // ⌘⇧D can beat a queued upload to the punch; the attachment ids only exist
        // once the uploads have landed.
        await waitForUploads()
        // Likewise a first save still creating the server draft: sent without
        // its id, the message would go out and leave that draft orphaned.
        await waitForDraftCreation()
        // The account can be signed out during those waits; nothing may go out
        // through an outbox whose graph is gone.
        guard !isAccountSignedOut, !isClosed else {
            if let reason = sendHoldReason { status = .failed(reason) }
            return false
        }
        commitRecipients()
        guard !hasInvalidAddresses else {
            status = .failed(hint(for: .to) ?? hint(for: .cc) ?? hint(for: .bcc) ?? "Check the recipients.")
            // The local checks are the same failures the server would report, so
            // they are reported the same way — the kind only, never the address.
            record(.sendFailed(kind: .invalidRecipient))
            return false
        }
        if draft.allRecipients.isEmpty, draft.mode.replyToMessageID == nil {
            status = .failed(OutboxError.noRecipients.localizedDescription)
            record(.sendFailed(kind: .noRecipients))
            return false
        }
        status = .sending
        // Captured BEFORE the send: sending CONSUMES the server draft (the
        // outbox deletes it afterwards), so this is the last moment its id is
        // knowable — and the Drafts folder has to drop the row now rather than
        // show a draft that no longer exists until the next poll.
        let serverDraftID = draft.serverDraft?.id
        let binding = outboxBinding
        do {
            let receipt = try await outbox.send(draft)
            // ONLY the send identity is taken from the receipt: it carries the
            // ROTATED key, so a composer reused for a second message is not
            // deduped away as a replay of the one that just went out. Assigning
            // the receipt's whole draft would revert anything typed during the
            // round trip — the rule `adoptServerState(from:sent:)` exists for.
            draft.adoptSendAttemptKey(from: receipt.draft)
            isClosed = true
            // Counts and two booleans only — never an address, a subject or a
            // file name.
            record(.messageSent(
                attachments: UsageBucket(count: draft.uploadedAttachments.count),
                hasCC: !draft.cc.isEmpty,
                hasBCC: !draft.bcc.isEmpty
            ))
            if let serverDraftID { draftCache(.removed(serverDraftID)) }
            return true
        } catch {
            // Nothing is discarded: the window stays open with everything in it.
            logger.warning("Send failed: \(error.logCode, privacy: .public)")
            // `send` throws a typed `OutboxError`, so there is nothing to unwrap
            // — and the kind is all that is kept.
            record(.sendFailed(kind: UsageOutboxErrorKind(error)))
            if case .sendOnHold(let hold) = error { sendHold = hold }
            fail(error, binding: binding)
            return false
        }
    }

    /// Whether a ``send()`` call is running, from its first line — including the
    /// waits before `status` says `.sending`.
    @ObservationIgnored private var isSendInFlight = false

    func discard() async {
        cancelAutosave()
        cancelAllUploads()
        isClosed = true
        record(.composeDiscarded)
        // A signed-out account's server draft is not ours to delete any more;
        // closing the window is all "Delete" can mean here.
        guard !isAccountSignedOut else { return }
        // A first save still creating the server draft would otherwise land
        // AFTER this delete and leave the draft the user threw away behind.
        await waitForDraftCreation()
        guard !isAccountSignedOut else { return }
        let serverDraftID = draft.serverDraft?.id
        do {
            try await outbox.discard(draft)
        } catch {
            logger.warning("Discarding the draft failed: \(error.logCode, privacy: .public)")
        }
        // Unconditional: `discard` is 404-tolerant, so "the delete threw" does not
        // mean the draft survived — and a row left behind for a draft the user
        // explicitly threw away is worse than one extra poll's correction.
        if let serverDraftID { draftCache(.removed(serverDraftID)) }
    }

    /// ⌘W: close outright, or ask first when there is unsaved work.
    func requestClose() {
        if hasUnsavedChanges {
            confirmsClose = true
        } else {
            close()
        }
    }

    /// Closes without deleting the server draft — "Save" in the close sheet.
    func saveAndClose() async {
        cancelAutosave()
        // The close sheet's Save Draft on a composer whose account is gone:
        // nothing can be saved, and the window must say so — `saveNow` returns
        // silently, and the bar already shows the same failure, so without this
        // the button did nothing at all. The window stays, text and all.
        guard !isAccountSignedOut else {
            status = .failed(Self.accountSignedOutSaveReason)
            announce(Self.accountSignedOutSaveReason)
            return
        }
        await waitForUploads()
        await saveNow()
        guard status.message == nil else { return } // Save failed: keep the window.
        isClosed = true
    }

    func close() {
        cancelAutosave()
        isClosed = true
    }

    /// Called from the window when it actually goes away, so no timer — and no
    /// upload waiting on a window that no longer exists — outlives it.
    func stop() {
        cancelAutosave()
        cancelAllUploads()
    }

    // MARK: - Attachments

    /// One upload the user can see and cancel while it is happening.
    struct PendingUpload: Identifiable, Equatable {
        let id = UUID()
        let filename: String
        /// `nil` when the file could not be stat'd; the chip then shows no size.
        let byteCount: Int?
    }

    /// Uploads in flight, oldest first. Rendered as spinner chips beside the
    /// finished ones — an upload that shows nothing until it lands reads as a
    /// no-op on a slow link, and the user picks the file again.
    private(set) var pendingUploads: [PendingUpload] = []
    @ObservationIgnored private var uploadTasks: [PendingUpload.ID: Task<Void, Never>] = [:]
    /// The tail of the upload queue. Uploads MUST run one at a time: the limits
    /// are per draft, and two concurrent uploads each measure the total against
    /// the same pre-upload draft, so a pair that only fits individually would both
    /// pass the check and the server would 413 the second.
    @ObservationIgnored private var uploadChain: Task<Void, Never>?
    @ObservationIgnored private var enqueuedCount = 0

    /// Runs the open panel and uploads whatever the user picked.
    ///
    /// The app is sandboxed: the URL the panel hands back carries the read grant,
    /// so it is passed straight to the outbox rather than copied or re-derived.
    func addAttachments() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        guard await panel.begin() == .OK else { return }
        await attach(panel.urls)
    }

    /// Attaches a batch — a multi-file open panel, drop or paste.
    ///
    /// Every file gets its chip at once and the uploads then run one after
    /// another: the user sees what they dropped immediately, and the per-draft
    /// limit is still measured against a draft that includes the file before it.
    func attach(_ urls: [URL], staged: Set<URL> = []) async {
        // ONE filter for every entry point (panel, drop, paste): a directory
        // reaches the outbox as an unreadable file, and a promise-backed or
        // remote URL as nothing at all.
        // Nothing goes to a server whose account is gone — not even a file.
        guard !isAccountSignedOut else {
            for url in staged { AttachmentScratchpad.discard(url) }
            status = .failed(Self.accountSignedOutReason)
            announce(Self.accountSignedOutReason)
            return
        }
        let files = urls.filter(Self.isAttachableFile)
        if files.isEmpty {
            if !urls.isEmpty { status = .failed("Herald can attach files, not folders.") }
            return
        }
        for url in staged.subtracting(files) { AttachmentScratchpad.discard(url) }
        let tasks = files.map { enqueue($0, isStaged: staged.contains($0)) }
        for task in tasks { await task.value }
    }

    /// Whether a URL names a real, readable file.
    ///
    /// The scope is claimed FIRST: a URL that only becomes reachable inside its
    /// security scope would otherwise stat as missing and be filtered away, and
    /// the drop would silently do nothing.
    private static func isAttachableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// - Parameter isStaged: true for a file Herald itself wrote to the scratchpad
    ///   (a pasted image), which is deleted once the upload is over. A file the
    ///   USER chose is never deleted.
    func attach(_ url: URL, isStaged: Bool = false) async {
        await attach([url], staged: isStaged ? [url] : [])
    }

    /// Puts the chip up now and the upload at the end of the queue.
    private func enqueue(_ url: URL, isStaged: Bool) -> Task<Void, Never> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let pending = PendingUpload(filename: url.lastPathComponent, byteCount: size)
        pendingUploads.append(pending)
        let previous = uploadChain
        enqueuedCount += 1
        let position = enqueuedCount
        let task = Task {
            await previous?.value
            await self.upload(url, as: pending, isStaged: isStaged)
            // Release the chain once the LAST enqueued upload is done, so a
            // composer left open for a day does not hold every finished Task.
            if position == self.enqueuedCount { self.uploadChain = nil }
        }
        uploadChain = task
        uploadTasks[pending.id] = task
        return task
    }

    private func upload(_ url: URL, as pending: PendingUpload, isStaged: Bool) async {
        // Cancelled while queued behind another upload: nothing has been read or
        // sent, so this is a clean no-op — minus the staged file, which is ours.
        guard !Task.isCancelled else {
            if isStaged { AttachmentScratchpad.discard(url) }
            return
        }
        // A dropped or panel-picked URL arrives with a sandbox extension already
        // consumed, but a bookmark-derived one would not; claiming access is
        // correct for both and a no-op for the first.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if isStaged { AttachmentScratchpad.discard(url) }
            pendingUploads.removeAll { $0.id == pending.id }
            uploadTasks[pending.id] = nil
        }

        // Uploading onto a draft with no server id creates one first: wait out
        // a create already in flight (see ``waitForDraftCreation()``), and
        // claim the slot when this upload is the one creating.
        await waitForDraftCreation()
        guard !Task.isCancelled else { return }
        status = .saving
        var sent = draft
        var binding = outboxBinding
        // The server draft is created HERE, as a save, rather than inside
        // `outbox.attach`: an attach that creates the draft and then fails
        // (413, unreadable file, network, a cancel from Delete Draft) throws
        // the new draft's id away with the error, and the next save would
        // create a second one. Skipped for a file the limits already refuse,
        // so a rejected file leaves no empty draft behind — attach refuses it
        // before any request. The slot is released as soon as the id is
        // adopted, not after the (possibly long) upload.
        var creating = beginDraftCreation(for: sent)
        defer { endDraftCreation(creating) }
        do {
            if creating, !Self.limitsRefuse(pending.byteCount, onto: sent) {
                let created = try await outbox.saveDraft(sent)
                draft.adoptServerState(from: created, sent: sent)
                publishDraftState()
                endDraftCreation(creating)
                creating = false
                // The upload goes through the CURRENT outbox (a re-auth may have
                // rebound the composer while the create was out), so a failure
                // is judged against the binding it actually started on.
                sent = draft
                binding = outboxBinding
            }
            let saved = try await outbox.attach(url, to: sent)
            // Adopted even when this upload was CANCELLED: the bytes reached the
            // server, so the local attachment list has to include them or every
            // later per-draft total is measured short and the server 413s the
            // next upload. Cancellation only suppresses the status change.
            draft.adoptServerState(from: saved, sent: sent)
            // Published for the same reason it is adopted above, cancellation
            // included: the bytes are on the server draft, so the Drafts folder's
            // copy has to say so too.
            publishDraftState()
            if status == .saving, !Task.isCancelled { status = .idle }
        } catch {
            logger.warning("Attachment failed: \(error.logCode, privacy: .public)")
            guard !Task.isCancelled else { return }
            fail(error, binding: binding)
        }
    }

    /// Whether the server's attachment limits refuse this file outright (the
    /// same check `OutboxService.attach` makes before any request). Unknown
    /// size: not refused here.
    private static func limitsRefuse(_ byteCount: Int?, onto draft: ComposeDraft) -> Bool {
        guard let byteCount else { return false }
        return AttachmentLimits.server.rejection(forAdding: byteCount, to: draft.uploadedAttachments) != nil
    }

    /// Stops waiting on an upload and takes its chip away.
    ///
    /// The request itself may still land — the server has no cancel — so the
    /// attachment can still appear as a finished chip a moment later. That is
    /// honest: the file IS on the draft, and the same remove button takes it off.
    func cancelUpload(_ id: PendingUpload.ID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        pendingUploads.removeAll { $0.id == id }
        if status == .saving, pendingUploads.isEmpty { status = .idle }
    }

    private func cancelAllUploads() {
        for id in Array(uploadTasks.keys) { cancelUpload(id) }
    }

    /// Waits for every queued upload. Called before sending, so a message can
    /// never leave without the file the user just dropped on it.
    func waitForUploads() async {
        await uploadChain?.value
    }

    /// Files dropped on the window. Directories are ignored rather than walked:
    /// dropping a folder on a mail composer means "the files in it" to almost
    /// nobody, and a deep tree is a very expensive misunderstanding.
    func drop(_ urls: [URL]) async {
        await attach(urls)
    }

    /// ⌘V: attaches file URLs, or writes a pasted image to scratch and attaches that.
    ///
    /// - Returns: whether the paste was consumed. `false` means the pasteboard held
    ///   nothing attachable and the caller must forward ⌘V to the text view — a
    ///   composer that eats plain-text paste is worse than one that never attaches.
    @discardableResult
    func paste(_ contents: PasteboardContents) async -> Bool {
        let pasted = AttachmentPasteboard.attachments(from: contents)
        guard !pasted.isEmpty else { return false }

        var urls: [URL] = []
        var staged: Set<URL> = []
        for item in pasted {
            switch item {
            case .file(let url):
                urls.append(url)
            case .image(let image, let filename):
                do {
                    // Off-main: a full-screen bitmap off the pasteboard is tens of
                    // MiB, and writing it here would freeze the window mid-⌘V.
                    let url = try await Task.detached(priority: .userInitiated) { @Sendable in
                        try AttachmentScratchpad.stage(image.data, filename: filename)
                    }.value
                    urls.append(url)
                    staged.insert(url)
                } catch {
                    logger.warning("Could not stage a pasted image: \(error.localizedDescription, privacy: .private)")
                    status = .failed("Herald could not read the pasted image.")
                }
            }
        }
        guard !urls.isEmpty else { return true }
        await attach(urls, staged: staged)
        return true
    }

    func removeAttachment(_ attachment: DraftAttachment) async {
        guard !isAccountSignedOut else { return }
        let sent = draft
        let binding = outboxBinding
        do {
            let saved = try await outbox.removeAttachment(attachment.id, from: sent)
            draft.adoptServerState(from: saved, sent: sent)
            publishDraftState()
        } catch {
            logger.warning("Removing an attachment failed: \(error.logCode, privacy: .public)")
            fail(error, binding: binding)
        }
    }
}
