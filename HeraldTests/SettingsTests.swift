import Foundation
import HeraldKit
import Observation
import Synchronization
import SwiftUI
import Testing
@testable import Herald

/// The Settings window's logic (R7): the route and its deep-link helper, the
/// observable account tint, the density storage, which domains the sidebar
/// lists, and the gate in front of Sign Out.
@MainActor
@Suite(.scratchDefaults) struct SettingsTests {
    private static func account(_ host: String) -> Account {
        Account(origin: URL(string: "https://\(host)")!, clientID: "cid", scopes: [])
    }

    private static func mailbox(_ id: String, _ address: String, domainID: String) -> Mailbox {
        SignatureSettingsTests.mailbox(id: id, address: address, domainID: domainID)
    }

    /// An environment with `hosts` signed in (the first one selected), backed
    /// by an in-memory account store so sign-out can run for real.
    private static func environment(
        _ hosts: [String],
        mailboxes: [String: [Mailbox]] = [:]
    ) async throws -> (AppEnvironment, [Account]) {
        let accounts = hosts.map(account)
        let environment = AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: accounts)),
            defaults: ScratchDefaults.make()
        )
        let store = try MailStore.inMemory()
        for account in accounts {
            if let boxes = mailboxes[account.host] {
                _ = try await store.upsertMailboxes(boxes, accountID: account.id)
            }
        }
        for (index, account) in accounts.enumerated() {
            await environment.install(account: account, api: FakeMailAPIClient(), store: store, select: index == 0)
            await environment.graphs[account.id]?.mail.reloadMailboxes()
        }
        return (environment, accounts)
    }

    // MARK: - Route resolution

    /// A route is a request: a domain the account no longer lists falls back
    /// to the account's own page (not the root), and without an account the
    /// account-level pages fall back to General. Fails if a stale deep link
    /// could leave the detail pane on a page with nothing behind it.
    @Test func aRouteResolvesAgainstWhatTheAccountStillShows() {
        let domain = SettingsRoute.domain("dom_a", .mailboxes)
        #expect(domain.resolved(hasAccount: true, visibleDomainIDs: ["dom_a"]) == domain)
        #expect(domain.resolved(hasAccount: true, visibleDomainIDs: ["dom_b"]) == .account)
        #expect(domain.resolved(hasAccount: false, visibleDomainIDs: ["dom_a"]) == .general)
        #expect(SettingsRoute.account.resolved(hasAccount: false, visibleDomainIDs: []) == .general)
        #expect(SettingsRoute.signatures.resolved(hasAccount: false, visibleDomainIDs: []) == .general)
        #expect(SettingsRoute.signatures.resolved(hasAccount: true, visibleDomainIDs: []) == .signatures)
        #expect(SettingsRoute.privacy.resolved(hasAccount: false, visibleDomainIDs: []) == .privacy)
    }

    @Test func theBreadcrumbNamesHeraldTheAccountOrTheDomain() {
        #expect(SettingsRoute.general.breadcrumb(accountLabel: "Studio", domainName: nil) == "Settings › Herald")
        #expect(SettingsRoute.privacy.breadcrumb(accountLabel: "Studio", domainName: nil) == "Settings › Herald")
        #expect(SettingsRoute.account.breadcrumb(accountLabel: "Studio", domainName: nil) == "Settings › Studio")
        #expect(
            SettingsRoute.domain("d", .overview).breadcrumb(accountLabel: "Studio", domainName: "acme.co")
                == "Settings › Studio › acme.co"
        )
    }

    // MARK: - Deep link

    /// `openSettings` takes no argument, so the helper must set the route
    /// BEFORE opening the window, open it exactly once, and bring the named
    /// account to the front. Fails if the window opens on the old route.
    @Test func showSettingsSetsTheRouteBeforeOpeningAndSwitchesTheAccount() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com", "b.example.com"])
        #expect(environment.selectedAccountID == accounts[0].id)

        var routeSeenWhenOpened: SettingsRoute?
        var opens = 0
        environment.showSettings(.account, accountID: accounts[1].id) {
            opens += 1
            routeSeenWhenOpened = environment.settingsRoute
        }

        #expect(opens == 1)
        #expect(routeSeenWhenOpened == .account)
        #expect(environment.selectedAccountID == accounts[1].id)
    }

    /// An account id that is not signed in must not leave Settings on no
    /// account; the route still applies.
    @Test func showSettingsIgnoresAnAccountThatIsNotSignedIn() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com"])
        environment.showSettings(.signatures, accountID: "https://gone.example.com") {}
        #expect(environment.selectedAccountID == accounts[0].id)
        #expect(environment.settingsRoute == .signatures)
    }

    /// Deep-linking to a domain before its mailboxes are known keeps the
    /// REQUEST (so it opens once they load) while drawing the account page.
    @Test func aDomainRouteWaitsForItsDomainWithoutLosingTheRequest() async throws {
        let (environment, accounts) = try await Self.environment(
            ["a.example.com"],
            mailboxes: ["a.example.com": [Self.mailbox("m1", "sales@acme.co", domainID: "dom_acme")]]
        )
        environment.showSettings(.domain("dom_later", .overview)) {}
        #expect(environment.resolvedSettingsRoute == .account)
        #expect(environment.settingsRoute == .domain("dom_later", .overview))

        environment.showSettings(.domain("dom_acme", .mailboxes), accountID: accounts[0].id) {}
        #expect(environment.resolvedSettingsRoute == .domain("dom_acme", .mailboxes))
    }

    /// Domain ids belong to one account: switching accounts from the Settings
    /// card leaves a domain page for the new account's Account page, and
    /// leaves any other page alone.
    @Test func switchingAccountFromSettingsLeavesADomainPage() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com", "b.example.com"])
        environment.settingsRoute = .domain("dom_a", .overview)
        environment.selectAccountFromSettings(accounts[1].id)
        #expect(environment.selectedAccountID == accounts[1].id)
        #expect(environment.settingsRoute == .account)

        environment.settingsRoute = .privacy
        environment.selectAccountFromSettings(accounts[0].id)
        #expect(environment.settingsRoute == .privacy)
    }

    // MARK: - Account tint

    /// The override is read through `AppEnvironment` and is OBSERVABLE: a
    /// view that drew the tint is invalidated when Settings changes it, and
    /// again when Reset clears it. Fails if the write only reached
    /// `UserDefaults` (which Observation cannot see) — the avatar would keep
    /// its old colour until something unrelated redrew it.
    @Test func changingTheAccountTintInvalidatesItsReaders() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com"])
        let id = accounts[0].id
        let hashDefault = AccountTintAssignment.defaultToken(forAccountID: id)
        #expect(environment.accountTintName(for: id) == hashDefault)
        #expect(environment.hasAccountTintOverride(id) == false)

        let other = try #require(AccountTintAssignment.tokenNames.first { $0 != hashDefault })
        let invalidated = Mutex(false)
        withObservationTracking {
            _ = environment.accountTintName(for: id)
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        environment.setAccountTint(other, for: id)
        #expect(invalidated.withLock { $0 }, "A reader of the tint must be told it changed")
        #expect(environment.accountTintName(for: id) == other)
        #expect(environment.accountTint(for: id).name == other)
        #expect(environment.hasAccountTintOverride(id))
        #expect(environment.defaults.string(forKey: AccountTintAssignment.storageKey(accountID: id)) == other)

        let resetInvalidated = Mutex(false)
        withObservationTracking {
            _ = environment.hasAccountTintOverride(id)
        } onChange: {
            resetInvalidated.withLock { $0 = true }
        }
        environment.setAccountTint(nil, for: id)
        #expect(resetInvalidated.withLock { $0 }, "Reset must invalidate too")
        #expect(environment.accountTintName(for: id) == hashDefault)
        #expect(environment.hasAccountTintOverride(id) == false)
        #expect(environment.defaults.object(forKey: AccountTintAssignment.storageKey(accountID: id)) == nil)
    }

    @Test func aTintNameOutsideTheSetIsRefused() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com"])
        let id = accounts[0].id
        environment.setAccountTint("chartreuse", for: id)
        #expect(environment.hasAccountTintOverride(id) == false)
        #expect(environment.defaults.object(forKey: AccountTintAssignment.storageKey(accountID: id)) == nil)
    }

    /// Two accounts keep separate colours.
    @Test func aTintOverrideIsPerAccount() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com", "b.example.com"])
        let before = environment.accountTintName(for: accounts[1].id)
        let pick = try #require(AccountTintAssignment.tokenNames.first { $0 != environment.accountTintName(for: accounts[0].id) })
        environment.setAccountTint(pick, for: accounts[0].id)
        #expect(environment.accountTintName(for: accounts[1].id) == before)
        #expect(environment.hasAccountTintOverride(accounts[1].id) == false)
    }

    // MARK: - Density

    /// The General page's segmented control writes the preference R2 defined
    /// (`list.density`), which the list reads through `ListDensity.current`.
    /// Fails on a typo'd key or a different default.
    @Test func theDensityControlWritesListDensity() {
        let defaults = ScratchDefaults.make()
        let storage = GeneralSettingsPage.densityStorage(store: defaults)
        #expect(storage.wrappedValue == .comfortable)
        #expect(ListDensity.current(in: defaults) == .comfortable)

        storage.wrappedValue = .compact
        #expect(defaults.string(forKey: "list.density") == "compact")
        #expect(ListDensity.current(in: defaults) == .compact)
    }

    @Test func theDensityControlReadsAnExistingChoice() {
        let defaults = ScratchDefaults.make()
        ListDensity.set(.compact, in: defaults)
        #expect(GeneralSettingsPage.densityStorage(store: defaults).wrappedValue == .compact)
    }

    // MARK: - Sidebar domains

    /// Hidden domains are not listed; the rest are, in `MailDomain` order.
    /// Monograms are assigned across ALL the account's domains, so hiding one
    /// of a clashing pair does not change the other's letters.
    @Test func theSidebarListsVisibleDomainsOnly() {
        let defaults = ScratchDefaults.make()
        let mailboxes = [
            Self.mailbox("m1", "sales@northwind.io", domainID: "dom_nw"),
            Self.mailbox("m2", "hello@notion.io", domainID: "dom_nt"),
            Self.mailbox("m3", "ops@acme.co", domainID: "dom_ac"),
        ]
        let all = SettingsDomainItem.visible(mailboxes: mailboxes, accountID: "acct", defaults: defaults)
        #expect(all.map(\.id) == ["dom_ac", "dom_nw", "dom_nt"])
        #expect(all.first { $0.id == "dom_nw" }?.monogram == "NOR")

        DomainPreferences.setHidden(true, accountID: "acct", domainID: "dom_nt", in: defaults)
        let visible = SettingsDomainItem.visible(mailboxes: mailboxes, accountID: "acct", defaults: defaults)
        #expect(visible.map(\.id) == ["dom_ac", "dom_nw"])
        #expect(visible.first { $0.id == "dom_nw" }?.monogram == "NOR", "Hiding a clash partner must not re-letter the other")

        // Another account's hidden flag is not this account's.
        #expect(SettingsDomainItem.visible(mailboxes: mailboxes, accountID: "other", defaults: defaults).count == 3)
    }

    /// A monogram override from Overview (R8) shows in the sidebar.
    @Test func theSidebarUsesAMonogramOverride() {
        let defaults = ScratchDefaults.make()
        DomainPreferences.setMonogramOverride("zz", accountID: "acct", domainID: "dom_ac", in: defaults)
        let items = SettingsDomainItem.visible(
            mailboxes: [Self.mailbox("m3", "ops@acme.co", domainID: "dom_ac")],
            accountID: "acct",
            defaults: defaults
        )
        #expect(items.first?.monogram == "ZZ")
    }

    // MARK: - Sign out

    /// "Sign Out…" only asks. Confirming signs out the account the dialog
    /// NAMED, even if the selection moved while it was open; a second confirm
    /// does nothing. Fails if the button signs out directly, or if confirm
    /// acts on whichever account is selected at the time.
    @Test func signOutAsksFirstAndSignsOutTheAccountItNamed() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com", "b.example.com"])
        let (a, b) = (accounts[0], accounts[1])

        environment.requestSettingsSignOut(accountID: a.id)
        #expect(environment.graphs[a.id] != nil, "Requesting must not sign out")
        #expect(environment.isConfirmingSettingsSignOut)
        let prompt = try #require(environment.settingsSignOutPrompt)
        #expect(prompt.accountID == a.id)
        #expect(prompt.accountLabel == a.label)

        environment.selectedAccountID = b.id
        await environment.confirmSettingsSignOut(prompt)
        #expect(environment.graphs[a.id] == nil)
        #expect(environment.graphs[b.id] != nil, "The selected account is not the one the dialog named")
        #expect(environment.isConfirmingSettingsSignOut == false)
        #expect(environment.settingsSignOutPrompt?.accountLabel == a.label, "The title keeps its text while dismissing")

        await environment.confirmSettingsSignOut(prompt)
        #expect(environment.graphs[b.id] != nil)
        #expect(environment.accountIDs == [b.id])
    }

    @Test func aCancelledOrSupersededPromptSignsNothingOut() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com", "b.example.com"])
        let (a, b) = (accounts[0], accounts[1])

        environment.requestSettingsSignOut(accountID: a.id)
        let cancelled = try #require(environment.settingsSignOutPrompt)
        environment.cancelSettingsSignOut()
        await environment.confirmSettingsSignOut(cancelled)
        #expect(environment.graphs[a.id] != nil)

        environment.requestSettingsSignOut(accountID: a.id)
        let stale = try #require(environment.settingsSignOutPrompt)
        environment.requestSettingsSignOut(accountID: b.id)
        await environment.confirmSettingsSignOut(stale)
        #expect(environment.graphs[a.id] != nil, "A superseded prompt must not act")
        #expect(environment.graphs[b.id] != nil)
    }

    // MARK: - Domain preferences write path

    /// The one write path for per-domain preferences must (a) invalidate every
    /// reader, (b) drop a hidden domain from the Settings sidebar, and (c)
    /// narrow what "All domains" lists in the account's view-model. Fails if a
    /// hide only lands in `UserDefaults` and nothing on screen follows it.
    @Test func updatingDomainPreferencesRepaintsReadersAndNarrowsAllDomains() async throws {
        let host = "a.example.com"
        let (environment, accounts) = try await Self.environment(
            [host],
            mailboxes: [host: [
                Self.mailbox("mb_acme", "sales@acme.co", domainID: "dom_acme"),
                Self.mailbox("mb_nw", "team@northwind.io", domainID: "dom_nw"),
            ]]
        )
        let id = accounts[0].id
        let mail = try #require(environment.graphs[id]?.mail)
        #expect(environment.settingsDomains(accountID: id).map(\.id) == ["dom_acme", "dom_nw"])
        #expect(mail.mailboxIDs(for: .allDomains) == nil, "Nothing excluded yet: the fast path")

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = environment.settingsDomains(accountID: id)
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        await environment.updateDomainPreferences(accountID: id) { defaults in
            DomainPreferences.setHidden(true, accountID: id, domainID: "dom_nw", in: defaults)
        }

        #expect(invalidated.withLock { $0 }, "A reader of the domain list must be told it changed")
        #expect(environment.settingsDomains(accountID: id).map(\.id) == ["dom_acme"])
        #expect(mail.mailboxIDs(for: .allDomains) == ["mb_acme", MailViewModel.unassignedMailboxKey])
    }

    /// The list column reads the tint from the account's view-model, not from
    /// the environment. A Settings write must invalidate that reader too, or
    /// rows keep the old colour until something unrelated redraws them.
    @Test func aTintChangeInvalidatesTheViewModelsTintReaders() async throws {
        let (environment, accounts) = try await Self.environment(["a.example.com"])
        let id = accounts[0].id
        let mail = try #require(environment.graphs[id]?.mail)
        let other = try #require(AccountTintAssignment.tokenNames.first { $0 != mail.accountTint?.name })

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = mail.listAccountTint
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        environment.setAccountTint(other, for: id)

        #expect(invalidated.withLock { $0 }, "The list column's tint must repaint")
        #expect(mail.listAccountTint?.name == other)
    }
}

private extension Account {
    var host: String { origin.host ?? "" }
}
