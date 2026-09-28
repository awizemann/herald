import Foundation
import HeraldKit
import Testing
@testable import Herald

/// V5 compose model: From candidates and defaults, the From/mailbox coupling,
/// Cc/Bcc visibility, recipient tokens, footer validation and Send enablement.
///
/// Fixture (on top of ``ScopeHarness``): an extra acme mailbox `mbInfo` whose
/// PRIMARY is info@acme.co, with a second sendable address support@acme.co and
/// a receive-only noreply@acme.co. Display-name order puts it first, so
/// info@acme.co is the account primary.
@MainActor
@Suite(.scratchDefaults)
struct ComposeFromTests {
    static func address(_ mailbox: String, _ address: String, primary: Bool, send: Bool = true, domain: String = ScopeHarness.acme) -> MailboxAddress {
        MailboxAddress(
            id: "addr_\(address)", mailboxID: mailbox, mailDomainID: domain, address: address,
            displayName: primary ? "Info Desk" : "", receiveEnabled: true, sendEnabled: send, isPrimary: primary
        )
    }

    static let infoMailbox = Mailbox(
        id: "mbInfo",
        address: "info@acme.co",
        addresses: [
            address("mbInfo", "support@acme.co", primary: false),
            address("mbInfo", "noreply@acme.co", primary: false, send: false),
            address("mbInfo", "info@acme.co", primary: true),
        ],
        displayName: "mbInfo",
        isActive: true,
        accessLevel: .manager,
        createdAt: MailFixtures.epoch,
        updatedAt: MailFixtures.epoch
    )

    static func harness() async throws -> ScopeHarness {
        let harness = try await ScopeHarness.make()
        try await harness.seed()
        try await harness.store.upsertMailboxes([infoMailbox], accountID: ScopeHarness.account)
        await harness.model.start()
        return harness
    }

    static func detail(
        id: String, mailbox: String, to: [String], cc: [String] = [], deliveredTo: String? = nil,
        from: String = "erik@halvorsen.no"
    ) -> MessageDetail {
        MessageDetail(
            summary: MailFixtures.message(id: id, mailboxID: mailbox, from: from, to: to),
            cc: cc, bcc: [], deliveredToAddress: deliveredTo, textBody: "hi", htmlAvailable: false,
            rfcMessageID: nil, inReplyTo: nil, references: [], attachments: []
        )
    }

    // MARK: - Default From matrix

    /// Scope → default From. Fails on the pre-V5 rule for the mailbox scope
    /// (it was the mailbox's first sendable — fine) and for the domain scope
    /// (it was the domain's first MAILBOX, not the account primary).
    @Test("A new message's From follows scope, then the account primary")
    func newMessageDefaultFromMatrix() async throws {
        let harness = try await Self.harness()
        #expect(harness.model.mailboxes.first?.id == "mbInfo", "fixture: mbInfo sorts first")

        // All domains → the account primary.
        var context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(context.fromAddress == "info@acme.co")
        #expect(context.mailboxID == "mbInfo")

        // Mailbox scope → that mailbox's sendable address.
        harness.model.selectScope(.mailbox("mbTeam"))
        await harness.settle()
        context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(context.fromAddress == "team@acme.co")
        #expect(context.mailboxID == "mbTeam")

        // Domain scope containing the primary → the primary.
        harness.model.selectScope(harness.acmeScope)
        await harness.settle()
        context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(context.fromAddress == "info@acme.co")

        // Domain scope without it → that domain's first sendable.
        let north = try #require(harness.model.domains.first { $0.name == "north.io" })
        harness.model.selectScope(.domain(north.id))
        await harness.settle()
        context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .new)))
        #expect(context.fromAddress == "ops@north.io")
        #expect(context.mailboxID == "mbOps")
        #expect(context.fromMailboxes.count == 4, "the picker gets every enabled mailbox")
    }

    /// The pure rule, including a mailbox whose addresses cannot send (falls
    /// back to the account primary rather than a From the server refuses).
    @Test func defaultAddressFallsBackToPrimaryWhenScopeCannotSend() {
        let mute = Mailbox(
            id: "mbMute", address: "mute@acme.co",
            addresses: [Self.address("mbMute", "mute@acme.co", primary: true, send: false)],
            displayName: "mute", isActive: true, accessLevel: .manager,
            createdAt: MailFixtures.epoch, updatedAt: MailFixtures.epoch
        )
        let mailboxes = [Self.infoMailbox, mute]
        let domains = MailDomain.domains(from: mailboxes)
        #expect(ComposeFrom.defaultAddress(scope: .mailbox("mbMute"), mailboxes: mailboxes, domains: domains)?.address == "info@acme.co")
        #expect(ComposeFrom.defaultAddress(scope: .allDomains, mailboxes: [mute], domains: domains) == nil)
    }

    /// Mail sent to sales@ is answered from sales@, even though the mailbox's
    /// primary is info@. Fails on the pre-V5 rule (always the primary).
    @Test("Reply, reply-all and forward go out from the address the original was sent to", arguments: [
        ComposeRequest.Kind.reply, .replyAll, .forward,
    ])
    func replyMatchesTheAddressSentTo(kind: ComposeRequest.Kind) async throws {
        let harness = try await Self.harness()
        await harness.api.setDetail(Self.detail(id: "m_sup", mailbox: "mbInfo", to: ["Acme Support <SUPPORT@acme.co>"]))
        let context = try #require(await harness.model.composeContext(
            for: ComposeRequest(kind: kind, messageID: "m_sup")
        ))
        #expect(context.fromAddress == "support@acme.co")
        #expect(context.mailboxID == "mbInfo")
    }

    @Test func replyMatchesCcAndDeliveredToThenFallsBackToPrimary() async throws {
        let harness = try await Self.harness()
        await harness.api.setDetail(Self.detail(id: "m_cc", mailbox: "mbInfo", to: ["x@else.com"], cc: ["support@acme.co"]))
        await harness.api.setDetail(Self.detail(id: "m_dt", mailbox: "mbInfo", to: ["list@else.com"], deliveredTo: "Support@Acme.co"))
        // Receive-only noreply@ is never a From, even when it was the recipient.
        await harness.api.setDetail(Self.detail(id: "m_nr", mailbox: "mbInfo", to: ["noreply@acme.co"]))
        for (id, expected) in [("m_cc", "support@acme.co"), ("m_dt", "support@acme.co"), ("m_nr", "info@acme.co")] {
            let context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .reply, messageID: id)))
            #expect(context.fromAddress == expected, "\(id)")
        }
    }

    /// A reopened draft keeps its stored From, whatever the scope says.
    @Test func draftKeepsItsStoredFrom() async throws {
        let harness = try await Self.harness()
        harness.model.selectScope(.mailbox("mbOps"))
        await harness.settle()
        let draft = Draft(
            id: "drf_s", version: 1, updatedAt: MailFixtures.epoch, attachments: [],
            content: DraftInput(mailboxID: "mbInfo", from: "support@acme.co", cc: ["c@x.co"], subject: "s")
        )
        _ = try await harness.store.reconcileDrafts([draft], accountID: ScopeHarness.account)
        let context = try #require(await harness.model.composeContext(for: ComposeRequest(kind: .draft, draftID: "drf_s")))
        #expect(context.fromAddress == "support@acme.co")
        #expect(context.mailboxID == "mbInfo")
        let model = ComposeViewModel(context: context, outbox: FakeOutbox(), autosaveDelay: .seconds(3600))
        #expect(model.showsCcBcc, "a draft with cc shows the rows")
    }

    // MARK: - Candidates

    static func composer(
        kind: ComposeRequest.Kind = .new,
        from: String = "info@acme.co",
        mailboxID: String = "mbInfo",
        outbox: FakeOutbox = FakeOutbox(),
        message: MessageDetail? = nil
    ) -> ComposeViewModel {
        let north = ScopeHarness.mailbox("mbOps", "ops@north.io", domain: ScopeHarness.north)
        let sales = ScopeHarness.mailbox("mbSales", "sales@acme.co", domain: ScopeHarness.acme)
        return ComposeViewModel(
            context: ComposeContext(
                kind: kind, mailboxID: mailboxID, fromAddress: from, message: message,
                fromMailboxes: [north, infoMailbox, sales]
            ),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
    }

    @Test("Candidates are grouped by domain, primary first, and filterable")
    func groupingAndFilter() {
        let model = Self.composer()
        #expect(model.fromGroups.map(\.domain) == ["acme.co", "north.io"])
        #expect(model.fromGroups[0].candidates.map(\.address)
            == ["info@acme.co", "sales@acme.co", "noreply@acme.co", "support@acme.co"], "each mailbox's primary first")
        #expect(model.fromGroups[0].candidates.first { $0.address == "noreply@acme.co" }?.canSend == false)
        #expect(model.selectedFrom?.address == "info@acme.co")

        model.fromFilter = "NORTH"
        #expect(model.fromGroups.map(\.domain) == ["north.io"])
        model.fromFilter = "info desk"
        #expect(model.fromGroups.flatMap(\.candidates).map(\.address) == ["info@acme.co"], "matches display name")
    }

    @Test func aNonSendableAddressCannotBePicked() {
        let model = Self.composer()
        let noreply = model.fromCandidates.first { $0.address == "noreply@acme.co" }!
        #expect(!model.selectFrom(noreply))
        #expect(model.draft.fromAddress == "info@acme.co")
        #expect(model.draft.mailboxID == "mbInfo")
    }

    // MARK: - From change

    private static func signature(_ id: String, _ scope: SignatureScope, label: String, name: String = "Sig") -> Signature {
        Signature(
            id: id, name: name, html: "", text: name, scope: scope, scopeID: "s", scopeLabel: label,
            isDefault: false, createdAt: MailFixtures.epoch, updatedAt: MailFixtures.epoch
        )
    }

    /// Picking From sets the address and the mailbox together, and a
    /// hand-picked signature the new address cannot use resets to automatic
    /// once its list arrives — but one it CAN use is kept.
    @Test func fromChangeMovesMailboxAndRevalidatesSignature() async {
        let outbox = FakeOutbox()
        let info = Self.signature("sig_info", .mailbox, label: "info@acme.co")
        let personal = Self.signature("sig_me", .user, label: "Me")
        await outbox.setSignatures(SignatureCandidates(automaticSignatureID: nil, signatures: [info, personal]))
        let model = Self.composer(outbox: outbox)
        await model.loadSignatures()
        model.signatureTag = "selected:sig_info"

        let ops = model.fromCandidates.first { $0.address == "ops@north.io" }!
        await outbox.setSignatures(SignatureCandidates(automaticSignatureID: nil, signatures: [personal]))
        #expect(model.selectFrom(ops))
        #expect(model.draft.fromAddress == "ops@north.io")
        #expect(model.draft.mailboxID == "mbOps")
        #expect(model.hasUnsavedChanges, "a From change alone is worth the close prompt")
        #expect(model.signatureCaption == nil, "the old address's list is dropped at once")

        await model.loadSignatures()
        #expect(await outbox.signatureRequests.last == "ops@north.io")
        #expect(model.draft.signature == .automatic)

        // A signature usable from the next address too survives the move.
        model.signatureTag = "selected:sig_me"
        let sales = model.fromCandidates.first { $0.address == "sales@acme.co" }!
        #expect(model.selectFrom(sales))
        await model.loadSignatures()
        #expect(model.draft.signature == .selected(id: "sig_me"))
        #expect(model.draft.mailboxID == "mbSales")
    }

    // MARK: - Cc / Bcc

    @Test func ccBccVisibilityRules() {
        let model = Self.composer()
        #expect(!model.showsCcBcc)
        model.showsCcBcc = true
        #expect(model.showsCcBcc)
        model.ccText = "c@x.co"
        model.showsCcBcc = false
        #expect(model.showsCcBcc, "a field with content is never hidden")
        model.ccText = ""
        #expect(!model.showsCcBcc)

        let message = Self.detail(id: "m", mailbox: "mbInfo", to: ["info@acme.co"])
        #expect(Self.composer(kind: .replyAll, message: message).showsCcBcc)
        #expect(!Self.composer(kind: .reply, message: message).showsCcBcc)
    }

    // MARK: - Tokens

    @Test("Token commit, paste and remove round-trip through the field string")
    func tokenRoundTrips() {
        let model = Self.composer()
        model.setPendingText("ada@example.com", for: .to)
        #expect(model.toText.isEmpty && model.pendingText(for: .to) == "ada@example.com")
        model.commitPending(.to)
        #expect(model.toText == "ada@example.com")
        #expect(model.draft.to == ["ada@example.com"])

        model.setPendingText("bob@example.com, car", for: .to)
        #expect(model.toText == "ada@example.com, bob@example.com")
        #expect(model.pendingText(for: .to) == "car")

        model.setPendingText("", for: .to)
        model.paste("x@y.co; z@y.co\nsupport@acme.co", into: .to)
        #expect(model.draft.to == ["ada@example.com", "bob@example.com", "x@y.co", "z@y.co", "support@acme.co"])
        let tokens = model.tokens(for: .to)
        #expect(tokens.last?.displayName == "mbInfo", "own address with no name of its own → its mailbox's")
        #expect(model.tokens(for: .to).first?.label == "ada@example.com")

        model.paste("partial", into: .cc)
        #expect(model.ccText.isEmpty && model.pendingText(for: .cc) == "partial")

        model.removeToken(at: 1, in: .to)
        #expect(model.toText == "ada@example.com, x@y.co, z@y.co, support@acme.co")
        #expect(model.removeLastToken(in: .to))
        #expect(model.draft.to == ["ada@example.com", "x@y.co", "z@y.co"])
        model.setPendingText("q", for: .to)
        #expect(!model.removeLastToken(in: .to), "Delete with text typed deletes text, not a token")
    }

    @Test func knownOwnAddressGetsItsName() {
        let model = Self.composer()
        model.toText = "INFO@acme.co, erik@halvorsen"
        let tokens = model.tokens(for: .to)
        #expect(tokens.map(\.displayName) == ["Info Desk", nil])
        #expect(tokens.map(\.isValid) == [true, false])
    }

    // MARK: - Validation and Send

    @Test func validationMessageAndSendEnablement() {
        let model = Self.composer()
        #expect(!model.isSendEnabled, "no recipient")
        #expect(model.validationMessage == nil)

        model.setPendingText("ada@example.com", for: .to)
        #expect(model.isSendEnabled, "a valid pending address counts: Send commits it")

        model.commitPending(.to)
        model.bccText = "erik@halvorsen"
        #expect(!model.isSendEnabled)
        #expect(model.validationMessage == "“erik@halvorsen” isn’t a valid address")

        model.ccText = "bad@"
        #expect(model.validationMessage == "“bad@” isn’t a valid address", "fields in To, Cc, Bcc order")
        model.ccText = ""
        model.bccText = ""
        #expect(model.isSendEnabled)
    }

    @Test func sendCommitsPendingText() async {
        let outbox = FakeOutbox()
        let model = Self.composer(outbox: outbox)
        model.setPendingText("ada@example.com", for: .to)
        #expect(await model.send())
        #expect(await outbox.lastSent?.to == ["ada@example.com"])
    }

    // MARK: - Signature caption

    @Test func signatureCaptionScopeWording() {
        #expect(ComposeViewModel.captionScope(of: Self.signature("a", .mailbox, label: "sales@acme.co")) == "Mailbox signature · sales@")
        #expect(ComposeViewModel.captionScope(of: Self.signature("b", .domain, label: "acme.co")) == "Domain default · acme.co")
        #expect(ComposeViewModel.captionScope(of: Self.signature("c", .user, label: "Ada")) == "Personal")
    }

    @Test func signatureCaptionFollowsAutomaticPick() async {
        let outbox = FakeOutbox()
        let domain = Self.signature("sig_dom", .domain, label: "acme.co", name: "Acme")
        await outbox.setSignatures(SignatureCandidates(automaticSignatureID: "sig_dom", signatures: [domain]))
        let model = Self.composer(outbox: outbox)
        await model.loadSignatures()
        #expect(model.signatureCaption == .init(name: "Acme", scope: "Domain default · acme.co"))
        model.signatureTag = "none"
        #expect(model.signatureCaption == nil)
    }

    @Test func windowTitle() {
        let model = Self.composer()
        #expect(model.windowTitle == "New Message")
        model.subject = "  Q3 plan "
        #expect(model.windowTitle == "Q3 plan")
    }
}
