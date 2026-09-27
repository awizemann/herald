import Foundation
import Testing

@testable import Herald

/// `AccountTintAssignment`: stable hash-based default, override precedence and
/// fallback for a stale/unknown override, and the storage key shape.
@Suite struct AccountTintAssignmentTests {
    @Test("The default token is always one of the eight named tokens")
    func defaultTokenIsAlwaysValid() {
        for id in ["origin-a", "origin-b", "https://mail.example.com", ""] {
            #expect(AccountTintAssignment.tokenNames.contains(AccountTintAssignment.defaultToken(forAccountID: id)))
        }
    }

    @Test("The default token is identical across repeated calls for the same account id — no per-process seeding")
    func defaultTokenIsStable() {
        let id = "https://hqbase.example.com"
        let first = AccountTintAssignment.defaultToken(forAccountID: id)
        let second = AccountTintAssignment.defaultToken(forAccountID: id)
        #expect(first == second)
    }

    @Test("Different account ids can (and, over the fixed 8-token set, generally do) land on different defaults")
    func differentAccountsCanDifferentiate() {
        let tokens = Set((0..<32).map { AccountTintAssignment.defaultToken(forAccountID: "account-\($0)") })
        // Not every one of 8 tokens need appear in 32 samples, but a broken hash
        // that always returns the same token would collapse this to size 1.
        #expect(tokens.count > 1)
    }

    @Test("A valid override wins over the hash default")
    func validOverrideWins() {
        let id = "account-1"
        let hashDefault = AccountTintAssignment.defaultToken(forAccountID: id)
        let other = AccountTintAssignment.tokenNames.first { $0 != hashDefault }!
        #expect(AccountTintAssignment.token(forAccountID: id, override: other) == other)
    }

    @Test("An override naming a token that does not exist falls back to the hash default, not to drawing nothing")
    func staleOverrideFallsBack() {
        let id = "account-1"
        let hashDefault = AccountTintAssignment.defaultToken(forAccountID: id)
        #expect(AccountTintAssignment.token(forAccountID: id, override: "not-a-real-token") == hashDefault)
    }

    @Test("A nil override resolves to the hash default")
    func nilOverrideResolvesToDefault() {
        let id = "account-1"
        #expect(
            AccountTintAssignment.token(forAccountID: id, override: nil)
                == AccountTintAssignment.defaultToken(forAccountID: id)
        )
    }

    @Test("The storage key is account.<accountID>.tint exactly")
    func storageKeyShape() {
        #expect(AccountTintAssignment.storageKey(accountID: "acct1") == "account.acct1.tint")
    }

    @Test("The token list is the exact 8-name contract with R1, in order")
    func tokenListContract() {
        #expect(AccountTintAssignment.tokenNames == ["clay", "ochre", "moss", "sage", "slate", "dusk", "plum", "rose"])
    }
}
