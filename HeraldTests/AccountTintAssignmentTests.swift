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

    /// Fails if the hash is swapped for `hashValue` (seeded per process, so
    /// every account would repaint on relaunch) or changed in any way while
    /// moving it (R3b moved it out of the retired mailbox-colour type): a
    /// same-process comparison cannot catch either, pinned literals can.
    ///
    /// The "a" value is NOT the textbook FNV-1a vector (`0xaf63dc4c8601ec8c`):
    /// the multiplier Herald has always used is `0x1000_0000_01b3`, one hex
    /// digit longer than the FNV prime. Pinned as-is — it is the contract the
    /// stored defaults were derived under (see ``AccountTintAssignment/stableHash(_:)``).
    @Test("The FNV-1a hash and the defaults it picks are pinned to literals")
    func hashIsPinned() {
        #expect(AccountTintAssignment.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(AccountTintAssignment.stableHash("a") == 0xaf74_d84c_8601_ec8c)
        #expect(AccountTintAssignment.defaultToken(forAccountID: "https://hqbase.example.com") == "sage")
        #expect(AccountTintAssignment.defaultToken(forAccountID: "https://mail.example") == "dusk")
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
