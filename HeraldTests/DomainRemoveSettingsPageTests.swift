import Foundation
import HeraldKit
import Testing

@testable import Herald

/// Redesign R9 — Settings › {domain} › Remove domain: `restoreDomain` (the
/// reverse of R4's `hideDomain`), the Hidden Domains list (`HiddenDomainItem`)
/// including its id-only-survivor fallback, Settings navigating itself off a
/// domain's Remove-domain page the moment it is hidden, and the HQBase Admin
/// URL builder (N5).
@MainActor
@Suite(.scratchDefaults)
struct DomainRemoveSettingsPageTests {
    private static func account(_ host: String = "a.example.com") -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    private static func mailbox(_ id: String, _ address: String, domainID: String) -> Mailbox {
        SignatureSettingsTests.mailbox(id: id, address: address, domainID: domainID)
    }

    private static func environment(mailboxes: [Mailbox], account: Account? = nil) async throws -> (AppEnvironment, Account) {
        let account = account ?? Self.account()
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [account])),
            defaults: ScratchDefaults.make()
        )
        let store = try MailStore.inMemory()
        if !mailboxes.isEmpty { _ = try await store.upsertMailboxes(mailboxes, accountID: account.id) }
        await environment.install(account: account, api: FakeMailAPIClient(), store: store, select: true)
        await environment.graphs[account.id]?.mail.reloadMailboxes()
        return (environment, account)
    }

    // MARK: - restoreDomain

    /// The reverse of `hideDomain`: clears both stored keys, and the domain
    /// reappears everywhere `settingsDomains` and the sidebar's own listing
    /// (`SidebarTests` covers hide; this is restore's mirror) read from.
    @Test("restoreDomain clears hidden/hiddenAt and the domain reappears in settingsDomains")
    func restoreDomainReappears() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        await environment.hideDomain("dom_acme", accountID: account.id)
        #expect(environment.settingsDomains(accountID: account.id).isEmpty)
        #expect(DomainPreferences.isHidden(accountID: account.id, domainID: "dom_acme", in: environment.defaults))

        await environment.restoreDomain("dom_acme", accountID: account.id)

        #expect(!DomainPreferences.isHidden(accountID: account.id, domainID: "dom_acme", in: environment.defaults))
        #expect(DomainPreferences.hiddenAt(accountID: account.id, domainID: "dom_acme", in: environment.defaults) == nil)
        #expect(environment.settingsDomains(accountID: account.id).map(\.id) == ["dom_acme"])
        #expect(environment.hiddenDomains(accountID: account.id).isEmpty)
    }

    /// The scenario R9 explicitly has to handle: every domain on the account
    /// hidden at once. `settingsDomains` (what the sidebar's Domains section
    /// and any domain's own Remove-domain page depend on) goes empty, so
    /// NOTHING in Settings can reach a domain's Remove-domain page any more —
    /// yet `hiddenDomains` still lists both, which is what lets
    /// `AccountSettingsPage` offer a restore path even then.
    @Test("Hiding every domain empties settingsDomains but hiddenDomains still lists them all, restorable")
    func hidingEveryDomainStillLeavesARestorePath() async throws {
        let (environment, account) = try await Self.environment(mailboxes: [
            Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme"),
            Self.mailbox("m2", "ops@north.io", domainID: "dom_north"),
        ])
        await environment.hideDomain("dom_acme", accountID: account.id)
        await environment.hideDomain("dom_north", accountID: account.id)

        #expect(environment.settingsDomains(accountID: account.id).isEmpty, "No domain's own Remove-domain page is reachable")
        let hidden = environment.hiddenDomains(accountID: account.id)
        #expect(Set(hidden.map(\.id)) == ["dom_acme", "dom_north"], "Both are still listed, and so still restorable")

        await environment.restoreDomain("dom_acme", accountID: account.id)
        #expect(environment.settingsDomains(accountID: account.id).map(\.id) == ["dom_acme"])
        #expect(environment.hiddenDomains(accountID: account.id).map(\.id) == ["dom_north"])
    }

    // MARK: - hiddenDomains(accountID:)

    /// `hideDomain` captures the domain's current name, so the list shows it
    /// with the right monogram and mailbox count while its mailboxes are still
    /// in the account's cache.
    @Test("A hidden domain still in the account's mailboxes lists its live name, monogram and mailbox count")
    func hiddenDomainListsLiveDetails() async throws {
        let (environment, account) = try await Self.environment(mailboxes: [
            Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme"),
            Self.mailbox("m2", "team@acme.co", domainID: "dom_acme"),
        ])
        await environment.hideDomain("dom_acme", accountID: account.id)

        let hidden = environment.hiddenDomains(accountID: account.id)
        #expect(hidden.count == 1)
        #expect(hidden.first?.name == "acme.co")
        #expect(hidden.first?.monogram == "AC")
        #expect(hidden.first?.mailboxCount == 2)
        #expect(hidden.first?.hiddenAt != nil)
    }

    /// A domain hidden while its mailboxes existed, then later dropped from the
    /// account's `mailboxes` snapshot entirely (e.g. every mailbox on it was
    /// removed on the server) must still be listable and restorable — the
    /// decision this phase makes is name-fallback, never silent purge. It
    /// falls back to the name captured at hide time, with a mailbox count of 0
    /// rather than a crash or a fabricated row.
    @Test("A hidden domain whose mailboxes are gone still lists via its captured name, count 0")
    func hiddenDomainSurvivesMailboxesDisappearing() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        await environment.hideDomain("dom_acme", accountID: account.id)

        let hiddenBefore = environment.hiddenDomains(accountID: account.id)
        #expect(hiddenBefore.first?.name == "acme.co", "Still resolvable while the mailbox is in the account's snapshot")

        // Simulate the mailbox truly disappearing: read the list against an
        // environment installed with NO mailboxes at all, same account and
        // same stored prefs.
        let bareEnvironment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: [account])),
            defaults: environment.defaults
        )
        let bareStore = try MailStore.inMemory()
        await bareEnvironment.install(account: account, api: FakeMailAPIClient(), store: bareStore, select: true)
        await bareEnvironment.graphs[account.id]?.mail.reloadMailboxes()

        let hiddenAfter = bareEnvironment.hiddenDomains(accountID: account.id)
        #expect(hiddenAfter.count == 1)
        #expect(hiddenAfter.first?.id == "dom_acme")
        #expect(hiddenAfter.first?.name == "acme.co", "Falls back to the name captured at hide time")
        #expect(hiddenAfter.first?.mailboxCount == 0)
    }

    /// A domain hidden before `hiddenName` existed (no stored name, and now
    /// gone from the account's mailboxes too) falls all the way back to its
    /// raw id — still listed, never dropped.
    @Test("A hidden domain with neither a live entry nor a stored name falls back to its raw id")
    func hiddenDomainFallsBackToRawID() {
        let defaults = ScratchDefaults.make()
        DomainPreferences.setHidden(true, accountID: "acct1", domainID: "dom_ghost", in: defaults)

        let items = HiddenDomainItem.hidden(mailboxes: [], accountID: "acct1", defaults: defaults)
        #expect(items.count == 1)
        #expect(items.first?.name == "dom_ghost")
        #expect(items.first?.mailboxCount == 0)
    }

    /// Audit F3 #3: a hidden domain whose mailboxes are all server-disabled
    /// must still be derivable (it says so), not fall to the "0 mailboxes"
    /// id-only path — that path is for a domain truly gone from the cache.
    /// `mail.mailboxes` (enabled only) can't tell those two apart; the fix
    /// passes `monogramMailboxes` (enabled + disabled) through `hiddenDomains`.
    @Test("A hidden domain fully disabled on the server says so, not \"0 mailboxes\"")
    func hiddenDomainAllMailboxesDisabledSaysSo() async throws {
        let disabledMailbox = MailboxAddress(
            id: "adr_m1", mailboxID: "m1", mailDomainID: "dom_acme", address: "sales@acme.co",
            displayName: "", receiveEnabled: true, sendEnabled: true, isPrimary: true, domainEnabled: false
        )
        let mailbox = Mailbox(
            id: "m1", address: "sales@acme.co", addresses: [disabledMailbox], displayName: "",
            isActive: true, accessLevel: .manager, createdAt: .now, updatedAt: .now
        )
        #expect(!mailbox.isEnabled, "the fixture must actually be server-disabled")

        let (environment, account) = try await Self.environment(mailboxes: [mailbox])
        // `mailboxes` (enabled only) is empty, so this must hide via the ONE
        // write path directly against stored prefs — `hideDomain` itself only
        // reads `mail.domains`, which a disabled domain never enters either.
        await environment.updateDomainPreferences(accountID: account.id) { defaults in
            DomainPreferences.setHidden(true, accountID: account.id, domainID: "dom_acme", in: defaults, name: "acme.co")
        }

        let hidden = environment.hiddenDomains(accountID: account.id)
        #expect(hidden.count == 1)
        #expect(hidden.first?.mailboxCount == 1, "the mailbox is still cached, just disabled")
        #expect(hidden.first?.allMailboxesDisabled == true)
    }

    /// The list orders newest hide first.
    @Test("Hidden domains list newest hide first")
    func hiddenDomainsOrderedNewestFirst() {
        let defaults = ScratchDefaults.make()
        DomainPreferences.setHidden(
            true, accountID: "acct1", domainID: "dom_old", in: defaults, name: "old.example",
            now: Date(timeIntervalSince1970: 1_000)
        )
        DomainPreferences.setHidden(
            true, accountID: "acct1", domainID: "dom_new", in: defaults, name: "new.example",
            now: Date(timeIntervalSince1970: 2_000)
        )

        let items = HiddenDomainItem.hidden(mailboxes: [], accountID: "acct1", defaults: defaults)
        #expect(items.map(\.id) == ["dom_new", "dom_old"])
    }

    // MARK: - Settings route navigates off a hidden domain's own page

    /// Hiding the domain the Settings window is currently showing (its own
    /// Remove-domain page) must not strand the user there: `resolvedSettingsRoute`
    /// falls back to `.account` the instant the write lands, because
    /// `settingsDomains` (what `SettingsRoute.resolved` checks against) no
    /// longer lists it. Restoring brings the very same stored route back.
    @Test("Hiding the domain shown in Settings navigates resolvedSettingsRoute off its Remove-domain page")
    func hidingCurrentSettingsDomainNavigatesAway() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        environment.settingsRoute = .domain("dom_acme", .remove)
        #expect(environment.resolvedSettingsRoute == .domain("dom_acme", .remove))

        await environment.hideDomain("dom_acme", accountID: account.id)
        #expect(environment.resolvedSettingsRoute == .account, "Never left resolving to a page for a now-hidden domain")
        // Audit F3 #4: the RAW route is rewritten too, not just left to
        // resolve away — otherwise `SettingsView`'s selection setter (which
        // compares against the raw route) treated a click on the already-
        // highlighted Account row as a no-op, so nothing ever moved the raw
        // route off the hidden domain, and a later Restore jumped straight
        // back to its Remove-domain page instead of staying on Account.
        #expect(environment.settingsRoute == .account, "hideDomain rewrites a route pointing inside the hidden domain")

        await environment.restoreDomain("dom_acme", accountID: account.id)
        #expect(environment.resolvedSettingsRoute == .account, "Restoring does not resurrect a route hiding already moved off")
    }

    /// Hiding a domain while Settings is on one of its OTHER pages (not
    /// `.remove`) must rewrite that too — the domain, not just the one page,
    /// is what left the sidebar.
    @Test("Hiding a domain rewrites the raw route from any of its pages, not just Remove domain")
    func hidingCurrentDomainFromOverviewPageNavigatesAway() async throws {
        let (environment, account) = try await Self.environment(
            mailboxes: [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]
        )
        environment.settingsRoute = .domain("dom_acme", .overview)

        await environment.hideDomain("dom_acme", accountID: account.id)

        #expect(environment.settingsRoute == .account)
    }

    /// Hiding a DIFFERENT domain than the one Settings is showing must not
    /// touch the raw route at all.
    @Test("Hiding an unrelated domain leaves the current route alone")
    func hidingUnrelatedDomainLeavesRouteAlone() async throws {
        let (environment, account) = try await Self.environment(mailboxes: [
            Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme"),
            Self.mailbox("m2", "ops@north.io", domainID: "dom_north"),
        ])
        environment.settingsRoute = .domain("dom_acme", .overview)

        await environment.hideDomain("dom_north", accountID: account.id)

        #expect(environment.settingsRoute == .domain("dom_acme", .overview))
    }

    // MARK: - HQBase Admin URL (N5)

    @Test("The admin URL is the account's https origin root, with no path/query")
    func adminURLIsOriginRoot() {
        let account = Account(origin: URL(string: "https://mail.example.com:8443")!, clientID: "cid", scopes: [])
        let url = AppEnvironment.hqBaseAdminURL(for: account)
        #expect(url?.absoluteString == "https://mail.example.com:8443")
        #expect(url?.path.isEmpty ?? false)
    }

    @Test("A non-https origin (should never happen — discovery already refuses it) is refused, not opened")
    func adminURLRefusesNonHTTPS() {
        let account = Account(origin: URL(string: "http://mail.example.com")!, clientID: "cid", scopes: [])
        #expect(AppEnvironment.hqBaseAdminURL(for: account) == nil)
    }

    // Audit F3 #2: `URLComponents.host` strips an IPv6 literal's brackets, so
    // rebuilding a fresh `URLComponents` from `.scheme`/`.host`/`.port` (the
    // old shape) silently produced no usable URL for one of these origins.
    @Test("An IPv6-literal origin's brackets survive — the fix reuses the original parse rather than `.host`")
    func adminURLKeepsIPv6Brackets() {
        let account = Account(origin: URL(string: "https://[2001:db8::1]:8443")!, clientID: "cid", scopes: [])
        let url = AppEnvironment.hqBaseAdminURL(for: account)
        #expect(url?.absoluteString == "https://[2001:db8::1]:8443")
    }

    @Test("Userinfo on the origin is dropped, never carried into the URL that leaves the app")
    func adminURLDropsUserinfo() {
        let account = Account(origin: URL(string: "https://alan:hunter2@mail.example.com")!, clientID: "cid", scopes: [])
        let url = AppEnvironment.hqBaseAdminURL(for: account)
        #expect(url?.absoluteString == "https://mail.example.com")
        #expect(url?.user == nil)
        #expect(url?.password == nil)
    }

    @Test("A path, query and fragment on the origin are all dropped — origin root only")
    func adminURLDropsPathQueryFragment() {
        let account = Account(origin: URL(string: "https://mail.example.com/admin/panel?x=1#frag")!, clientID: "cid", scopes: [])
        let url = AppEnvironment.hqBaseAdminURL(for: account)
        #expect(url?.absoluteString == "https://mail.example.com")
    }
}
