import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Audit W1 (the "now" half): an account IS its origin today, so Add Account for
/// an origin that is already signed in — possibly as another user — replaced
/// the existing account under the same id, rebound its composers and mixed two
/// mailboxes in one cache. Add Account now refuses it; re-auth is unaffected.
@MainActor
@Suite struct AddAccountGuardTests {
    private static let account = Account(
        origin: URL(string: "https://\(OAuTestServerConstants.host)")!,
        clientID: "cid_registered",
        scopes: []
    )
    private static let grant = OAuthTokens(accessToken: "live-access", refreshToken: "live-refresh")

    /// Fails if Add Account for a LIVE account's origin starts OAuth at all
    /// (the browser opens) or touches the stored grant — including when the
    /// address is typed with different case, a trailing slash, the explicit
    /// default port or a trailing root dot. The account is live but NOT in the
    /// store's index, so only the live-graph check can catch it.
    @Test(arguments: ["MAIL.test.invalid/", "https://mail.test.invalid:443", "mail.test.invalid."])
    func addAccountForALiveOriginIsRefusedBeforeOAuth(typed: String) async throws {
        let store = InMemoryAccountStore()
        try store.setTokens(Self.grant, for: Self.account.id)
        let presenter = ScriptedPresenter()
        presenter.completeNextAttempt()
        let environment = SignInRecoveryTests.environment(presenter: presenter, store: store)
        await environment.install(account: Self.account, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        await environment.signIn(originText: typed)

        #expect(presenter.attemptCount == 0, "OAuth started for an origin that is already signed in")
        #expect(environment.signInError?.contains("already signed in to mail.test.invalid") == true)
        #expect(environment.isSigningIn == false)
        #expect(environment.signInStage == nil)
        #expect(try store.tokens(for: Self.account.id) == Self.grant)
        await environment.signOut(accountID: Self.account.id)
    }

    /// The account may be in the Keychain without a graph (still queued behind
    /// the launch restore). Fails if only the live graphs are consulted.
    @Test func addAccountForAnOriginOnlyInTheIndexIsRefused() async throws {
        let store = InMemoryAccountStore(accounts: [Self.account])
        let presenter = ScriptedPresenter()
        presenter.completeNextAttempt()
        let environment = SignInRecoveryTests.environment(presenter: presenter, store: store)

        await environment.signIn(originText: SignInRecoveryTests.origin)

        #expect(presenter.attemptCount == 0)
        #expect(environment.signInError?.contains("already signed in") == true)
        #expect(environment.graphs.isEmpty)
    }

    /// The guard must be Add Account's alone. Fails if re-authentication — which
    /// deliberately signs an existing origin in again — is refused by it.
    @Test func reauthenticationIsNotRefused() async throws {
        let store = InMemoryAccountStore(accounts: [Self.account])
        try store.setTokens(Self.grant, for: Self.account.id)
        let presenter = ScriptedPresenter()
        presenter.completeNextAttempt()
        let environment = SignInRecoveryTests.environment(presenter: presenter, store: store)
        await environment.install(account: Self.account, api: FakeMailAPIClient(), store: try MailStore.inMemory())

        await environment.reauthenticate(accountID: Self.account.id)

        #expect(presenter.attemptCount == 1, "re-auth never reached the browser")
        #expect(environment.signInError == nil)
        #expect(try store.tokens(for: Self.account.id)?.accessToken == "hqb_access_1")
        await environment.signOut(accountID: Self.account.id)
    }

    // MARK: Unreadable account list (audit W2)

    /// Fails if Add Account opens the browser when the account list cannot be
    /// saved to — the consent would mint a grant the store then refuses.
    @Test func addAccountWithAnUnreadableIndexIsRefusedBeforeOAuth() async throws {
        let presenter = ScriptedPresenter()
        presenter.completeNextAttempt()
        let environment = SignInRecoveryTests.environment(presenter: presenter, store: UnreadableIndexStore())

        await environment.signIn(originText: SignInRecoveryTests.origin)

        #expect(presenter.attemptCount == 0)
        #expect(environment.signInError == AccountStoreError.indexUnreadable.localizedDescription)
    }

    /// Fails if an unreadable list ends the launch on "Herald could not start"
    /// (a dead end) or silently on a blank onboarding screen.
    @Test func launchWithAnUnreadableIndexShowsOnboardingWithTheReason() async throws {
        let environment = SignInRecoveryTests.environment(presenter: ScriptedPresenter(), store: UnreadableIndexStore())
        environment.store = try MailStore.inMemory()

        await environment.restoreAccounts()

        #expect(environment.phase == .signedOut)
        #expect(environment.signInError == AccountStoreError.indexUnreadable.localizedDescription)
    }
}

/// An account store whose index exists but cannot be read — what
/// `KeychainAccountStore` reports for a corrupt or foreign-format blob.
private nonisolated final class UnreadableIndexStore: AccountStore {
    private let backing = InMemoryAccountStore()
    func accounts() throws -> [Account] { throw AccountStoreError.indexUnreadable }
    func add(_ account: Account) throws { throw AccountStoreError.indexUnreadable }
    func remove(_ accountID: Account.ID) throws { throw AccountStoreError.indexUnreadable }
    func tokens(for accountID: Account.ID) throws -> OAuthTokens? { try backing.tokens(for: accountID) }
    func setTokens(_ tokens: OAuthTokens?, for accountID: Account.ID) throws { try backing.setTokens(tokens, for: accountID) }
    func clientID(for origin: URL) throws -> String? { try backing.clientID(for: origin) }
    func setClientID(_ clientID: String, for origin: URL) throws { try backing.setClientID(clientID, for: origin) }
}
