import Foundation
import HeraldKit
import Testing
@testable import Herald

/// The rules that decide whether Herald may open an authorization window BY
/// ITSELF. Every test here names the misbehaviour it fails on, because the
/// failure mode of this type is a browser window appearing at a moment nobody
/// asked for one.
@MainActor
@Suite struct AutoReauthPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fails if Herald would open a consent window while the user is working in
    /// ANOTHER app — the one behaviour that would be strictly worse than the
    /// banner it replaces.
    @Test func neverAttemptsWhileHeraldIsNotFrontmost() {
        var policy = AutoReauthPolicy()
        let inBackground = policy.begin(accountID: "a", isApplicationActive: false, now: now)
        #expect(inBackground == false)
        // And nothing was consumed: coming back to Herald must still repair it.
        let onceFrontmost = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(onceFrontmost)
    }

    /// Fails if a burst of failed passes (or a second expiry event) could open a
    /// second window over the one already up.
    @Test func onlyOneAttemptInFlightPerAccount() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        let second = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        #expect(second == false)
        #expect(policy.isAttempting(accountID: "a"))
        policy.finish(accountID: "a", succeeded: true, now: now)
        #expect(policy.isAttempting(accountID: "a") == false)
    }

    /// Fails if a cancelled attempt lets the next failed poll re-open the window:
    /// closing that window is the user saying "not now", and the banner is the
    /// fallback for exactly this.
    @Test func aFailedAttemptSuppressesTheNextOneUntilTheIntervalPasses() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        policy.finish(accountID: "a", succeeded: false, now: now)

        let justInside = now.addingTimeInterval(AutoReauthPolicy.retryInterval - 1)
        let tooSoon = policy.begin(accountID: "a", isApplicationActive: true, now: justInside)
        #expect(tooSoon == false)

        let after = now.addingTimeInterval(AutoReauthPolicy.retryInterval)
        let allowedAgain = policy.begin(accountID: "a", isApplicationActive: true, now: after)
        #expect(allowedAgain)
    }

    /// Fails if the cooldown were global: one account's dead web session must not
    /// stop a second account — a different server entirely — from repairing
    /// itself.
    @Test func theCooldownIsPerAccount() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        policy.finish(accountID: "a", succeeded: false, now: now)
        let other = policy.begin(accountID: "b", isApplicationActive: true, now: now)
        #expect(other)
    }

    /// A session that was repaired and expires again days later is a NEW event.
    /// Fails if a success left the cooldown behind and made the second expiry
    /// wait it out for no reason.
    @Test func aSuccessfulAttemptClearsTheCooldown() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        policy.finish(accountID: "a", succeeded: true, now: now)
        let nextExpiry = policy.begin(
            accountID: "a", isApplicationActive: true, now: now.addingTimeInterval(1)
        )
        #expect(nextExpiry)
    }

    /// Signing out and back in must not inherit the dead session's cooldown —
    /// nor a stuck in-flight flag, which would leave the banner claiming to be
    /// signing the user in forever.
    @Test func forgettingAnAccountDropsBothTheCooldownAndTheInFlightFlag() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        policy.forget(accountID: "a")
        #expect(policy.isAttempting(accountID: "a") == false)
        let afterForget = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(afterForget)
    }
}
