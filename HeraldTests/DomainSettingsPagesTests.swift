import Foundation
import HeraldKit
import Observation
import Synchronization
import Testing
@testable import Herald

/// Redesign R8 — the domain-level Settings pages (Overview, Mailboxes,
/// Signatures): the notify toggle's effective-value rule, the writes each
/// toggle/field makes (routed through `AppEnvironment.updateDomainPreferences`,
/// so they invalidate readers and reload), the mailbox table's filter/sort/
/// primary logic, and domain-scoped signature creation.
@MainActor
@Suite(.scratchDefaults) struct DomainSettingsPagesTests {
    // MARK: - Notify: effective value

    /// The rule ``MailViewModel/notificationSilencedMailboxIDs()`` enforces for
    /// real banners, restated for what the Overview toggle DRAWS: a global OFF
    /// always wins, `nil` follows the global setting, and an explicit value
    /// shows as itself once the global switch is on.
    @Test("Global OFF always wins; nil follows the global switch; an explicit value shows once global is on")
    func notifyEffectiveValue() {
        #expect(DomainNotifyEffective.effective(explicit: nil, globalEnabled: true) == true)
        #expect(DomainNotifyEffective.effective(explicit: true, globalEnabled: true) == true)
        #expect(DomainNotifyEffective.effective(explicit: false, globalEnabled: true) == false)
        #expect(DomainNotifyEffective.effective(explicit: nil, globalEnabled: false) == false)
        #expect(DomainNotifyEffective.effective(explicit: true, globalEnabled: false) == false, "An explicit true cannot override a global OFF")
        #expect(DomainNotifyEffective.effective(explicit: false, globalEnabled: false) == false)
    }

    // MARK: - Overview toggles route through the one write path

    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    private static func mailbox(_ id: String, _ address: String, domainID: String) -> Mailbox {
        SignatureSettingsTests.mailbox(id: id, address: address, domainID: domainID)
    }

    private static func environment(mailboxes: [Mailbox] = []) async throws -> (AppEnvironment, Account) {
        let account = Self.account("a.example.com")
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [account])),
            defaults: ScratchDefaults.make()
        )
        let store = try MailStore.inMemory()
        if !mailboxes.isEmpty { _ = try await store.upsertMailboxes(mailboxes, accountID: account.id) }
        await environment.install(account: account, api: FakeMailAPIClient(), store: store)
        await environment.graphs[account.id]?.mail.reloadMailboxes()
        return (environment, account)
    }

    /// Fails if a toggle writes straight to `UserDefaults` instead of through
    /// `updateDomainPreferences` — which is what invalidates every reader
    /// (the badge, the sidebar's own list) and reloads the account's lists.
    @Test("Include in All domains and Count in badge write through the one path and invalidate readers")
    func toggleWritesInvalidateReaders() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        let domainID = "dom_acme"

        #expect(DomainPreferences.includeInAll(accountID: account.id, domainID: domainID, in: environment.defaults))
        #expect(DomainPreferences.countInBadge(accountID: account.id, domainID: domainID, in: environment.defaults))

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = environment.domainPreferencesObserved()
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setIncludeInAll(false, accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(invalidated.withLock { $0 }, "A reader of the observed defaults must be told the write happened")
        #expect(DomainPreferences.includeInAll(accountID: account.id, domainID: domainID, in: environment.defaults) == false)

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setCountInBadge(false, accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(DomainPreferences.countInBadge(accountID: account.id, domainID: domainID, in: environment.defaults) == false)
    }

    /// Audit F3 #9: a monogram write (`reloads: false`) still bumps the
    /// observed revision (a reader still repaints) but does NOT pay for a
    /// full `reloadConversations` + `reloadDrafts` — unlike Include in All
    /// domains / Count in badge (`reloads` defaulted to `true`), which change
    /// what "All domains" and its drafts actually list.
    @Test("reloads: false repaints observers but skips the conversation/draft reload; the default still runs it")
    func reloadsFalseSkipsListReload() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        let domainID = "dom_acme"
        let model = try #require(environment.graphs[account.id]?.mail)
        let conversationsBefore = model.conversationReloadCount
        let draftsBefore = model.draftReloadCount

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = environment.domainPreferencesObserved()
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        await environment.updateDomainPreferences(accountID: account.id, reloads: false) { defaults in
            DomainPreferences.setMonogramOverride("XY", accountID: account.id, domainID: domainID, in: defaults)
        }

        #expect(invalidated.withLock { $0 }, "A reader of the observed defaults must still be told the write happened")
        #expect(model.conversationReloadCount == conversationsBefore, "reloads: false must not reload conversations")
        #expect(model.draftReloadCount == draftsBefore, "reloads: false must not reload drafts")

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setIncludeInAll(false, accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(model.conversationReloadCount > conversationsBefore, "the default (reloads: true) still reloads")
        #expect(model.draftReloadCount > draftsBefore)
    }

    /// The notify toggle writes an EXPLICIT true/false (never clears back to
    /// "follow global" from the switch itself) and the write is visible through
    /// the effective-value rule immediately.
    @Test("The notify toggle writes an explicit value that changes what's effective")
    func notifyToggleWritesExplicitValue() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        let domainID = "dom_acme"
        #expect(DomainPreferences.notify(accountID: account.id, domainID: domainID, in: environment.defaults) == nil)

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setNotify(false, accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(DomainPreferences.notify(accountID: account.id, domainID: domainID, in: environment.defaults) == false)
        #expect(
            DomainNotifyEffective.effective(
                explicit: DomainPreferences.notify(accountID: account.id, domainID: domainID, in: environment.defaults),
                globalEnabled: NotificationSettings.newMailEnabled(in: environment.defaults)
            ) == false
        )
    }

    // MARK: - Monogram field validation

    /// The field's own commit decision (`DomainMonogramField.commit(_:)`)
    /// calls `DomainMonogram.wouldCommitOverride(_:)` directly (audit F3 #11)
    /// — this exercises THAT function, not a second re-implementation of its
    /// two lines under a different name, which would keep passing even if the
    /// field's real logic diverged from it.
    @Test("Only a validating value or an empty field would commit; a mid-edit keystroke would not")
    func monogramFieldCommitRule() {
        #expect(DomainMonogram.wouldCommitOverride("") == true, "Clearing the field commits (clears the override)")
        #expect(DomainMonogram.wouldCommitOverride("AC") == true)
        #expect(DomainMonogram.wouldCommitOverride("NOR") == true)
        #expect(DomainMonogram.wouldCommitOverride("A") == false, "One letter, mid-typing, must not clear a stored override")
        #expect(DomainMonogram.wouldCommitOverride("ABCD") == false)
        #expect(DomainMonogram.wouldCommitOverride("A!") == false)
    }

    /// End to end: writing a validating override through `updateDomainPreferences`
    /// changes what the Settings sidebar (and this page's own badge) show.
    @Test("A committed monogram override is visible through updateDomainPreferences")
    func monogramOverrideWritesThrough() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        let domainID = "dom_acme"
        #expect(environment.settingsDomains(accountID: account.id).first?.monogram == "AC")

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setMonogramOverride("ZZ", accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(environment.settingsDomains(accountID: account.id).first?.monogram == "ZZ")

        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setMonogramOverride(nil, accountID: account.id, domainID: domainID, in: defaults)
        }
        #expect(environment.settingsDomains(accountID: account.id).first?.monogram == "AC", "Clearing returns to auto")
    }

    // MARK: - Mailbox table: filter, sort, primary

    private static func mailboxWithAddress(
        _ id: String, local: String, domainID: String, domainName: String,
        isPrimary: Bool, displayName: String, receive: Bool, send: Bool
    ) -> Mailbox {
        Mailbox(
            id: id,
            address: "\(local)@\(domainName)",
            addresses: [
                MailboxAddress(
                    id: "adr_\(id)", mailboxID: id, mailDomainID: domainID, address: "\(local)@\(domainName)",
                    displayName: displayName, receiveEnabled: receive, sendEnabled: send, isPrimary: isPrimary
                ),
            ],
            displayName: displayName, isActive: true, accessLevel: .manager,
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    /// Fails if a mailbox from a DIFFERENT domain leaks into the table, if the
    /// row order does not match `MailDomain`'s own deterministic order, or if
    /// the Primary pill / Receive / Send fields disagree with the address.
    @Test("The table lists only this domain's mailboxes, in MailDomain order, with the address's own fields")
    func mailboxTableFiltersSortsAndReadsFields() throws {
        let acmeSales = Self.mailboxWithAddress(
            "m_sales", local: "sales", domainID: "dom_acme", domainName: "acme.co",
            isPrimary: true, displayName: "Acme Sales", receive: true, send: true
        )
        let acmeBilling = Self.mailboxWithAddress(
            "m_billing", local: "billing", domainID: "dom_acme", domainName: "acme.co",
            isPrimary: false, displayName: "Acme Billing", receive: false, send: true
        )
        let northOps = Self.mailboxWithAddress(
            "m_ops", local: "ops", domainID: "dom_north", domainName: "north.io",
            isPrimary: true, displayName: "North Ops", receive: true, send: false
        )
        let domains = MailDomain.domains(from: [acmeSales, acmeBilling, northOps])
        let acme = try #require(domains.first { $0.name == "acme.co" })

        let rows = DomainMailboxesSettingsPage.rows(mailboxes: [acmeSales, acmeBilling, northOps], domain: acme)

        #expect(rows.map(\.id) == ["m_billing", "m_sales"], "billing sorts before sales; north's ops is excluded")
        let sales = try #require(rows.first { $0.id == "m_sales" })
        #expect(sales.localPart == "sales")
        #expect(sales.domainName == "acme.co")
        #expect(sales.isPrimary)
        #expect(sales.senderName == "Acme Sales")
        #expect(sales.canReceive)
        #expect(sales.canSend)

        let billing = try #require(rows.first { $0.id == "m_billing" })
        #expect(billing.isPrimary == false)
        #expect(billing.canReceive == false)
        #expect(billing.canSend)
    }

    /// A domain id `MailDomain` lists that the account's current `mailboxes`
    /// snapshot no longer has (a race with sync) must not crash or fabricate a
    /// blank row — it is skipped.
    @Test("A domain member the account's mailbox list does not have is skipped, not fabricated")
    func mailboxTableSkipsAMissingMember() {
        let domain = MailDomain(id: "dom_acme", name: "acme.co", mailboxIDs: ["m_sales", "m_gone"])
        let rows = DomainMailboxesSettingsPage.rows(
            mailboxes: [Self.mailboxWithAddress(
                "m_sales", local: "sales", domainID: "dom_acme", domainName: "acme.co",
                isPrimary: true, displayName: "Acme Sales", receive: true, send: true
            )],
            domain: domain
        )
        #expect(rows.map(\.id) == ["m_sales"])
    }

    // MARK: - Domain-scoped signature creation

    /// "New Signature" on a domain page must pre-select THAT domain, not
    /// whatever scope sorts first — the bug this exists to prevent is silently
    /// filing a domain's new signature under Personal or another mailbox.
    @Test("New Signature on a domain page pre-selects that domain's scope")
    func newSignaturePrefersTheDomainScope() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        let model = SignatureSettingsModel(
            service: service,
            mailboxes: {
                [
                    SignatureSettingsTests.mailbox(id: "m1", address: "sales@acme.co", domainID: "dom_acme"),
                    SignatureSettingsTests.mailbox(id: "m2", address: "ops@north.io", domainID: "dom_north"),
                ]
            }
        )
        await model.load()

        model.beginCreate(preferring: SignatureScopeRef(type: .domain, id: "dom_north"))
        #expect(model.editor?.scope == SignatureScopeRef(type: .domain, id: "dom_north"))
    }

    /// A preferred scope the account cannot currently manage (not among
    /// `scopeOptions` — e.g. its mailboxes have not loaded yet) must NEVER be
    /// silently substituted for a different scope (audit F3 #6): a signature
    /// created under a scope the caller did not ask for, with no indication
    /// it happened, is worse than the sheet simply not opening. Callers
    /// (the domain page's "New Signature") gate the button itself on
    /// ``SignatureSettingsModel/offersScope(_:)`` so this stays unreachable
    /// in the UI, but the model guards it too.
    @Test("A preferred scope not currently offered opens no sheet at all")
    func newSignatureRefusesWhenPreferredScopeIsUnavailable() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        let model = SignatureSettingsModel(
            service: service,
            mailboxes: { [SignatureSettingsTests.mailbox(id: "m1", address: "sales@acme.co", domainID: "dom_acme")] }
        )
        await model.load()
        #expect(!model.scopeOptions.isEmpty, "the fixture must offer SOME scope, just not the requested one")

        model.beginCreate(preferring: SignatureScopeRef(type: .domain, id: "dom_nowhere"))
        #expect(model.editor == nil, "no sheet, under no scope, rather than a silently substituted one")
    }

    /// ``SignatureSettingsModel/offersScope(_:)`` is what a domain page's
    /// "New Signature" button disables on — exact per-domain, not the looser
    /// "is anything offered at all" `scopeOptions.isEmpty`.
    @Test("offersScope is exact to the requested domain, not just non-empty scopeOptions")
    func offersScopeIsExactToTheRequestedDomain() async {
        let service = FakeSignatureManaging(listResult: .success([]))
        let model = SignatureSettingsModel(
            service: service,
            mailboxes: { [SignatureSettingsTests.mailbox(id: "m1", address: "sales@acme.co", domainID: "dom_acme")] }
        )
        await model.load()

        #expect(model.offersScope(SignatureScopeRef(type: .domain, id: "dom_acme")))
        #expect(!model.offersScope(SignatureScopeRef(type: .domain, id: "dom_nowhere")))
    }

    /// The domain Signatures page's own filter: only that domain's group, never
    /// another domain's or a mailbox's/personal signature leaking in.
    @Test("A domain's signature list is exactly its own scope group")
    func domainSignatureFilterIsExact() async {
        let acme = SignatureSettingsTests.signature(id: "s1", name: "Acme footer", scope: .domain, scopeID: "dom_acme", scopeLabel: "acme.co")
        let north = SignatureSettingsTests.signature(id: "s2", name: "North footer", scope: .domain, scopeID: "dom_north", scopeLabel: "north.io")
        let personal = SignatureSettingsTests.signature(id: "s3", name: "Mine", scope: .user, scopeID: "u1", scopeLabel: "Me")
        let service = FakeSignatureManaging(listResult: .success([acme, north, personal]))
        let model = SignatureSettingsModel(service: service, mailboxes: { [] })
        await model.load()

        let acmeGroup = model.groups.first { $0.scope == .domain && $0.scopeID == "dom_acme" }
        #expect(acmeGroup?.signatures.map(\.id) == ["s1"])
        let northGroup = model.groups.first { $0.scope == .domain && $0.scopeID == "dom_north" }
        #expect(northGroup?.signatures.map(\.id) == ["s2"])
    }
}
