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

    /// A session the USER repaired, expiring again later, is a NEW event.
    /// Fails if a user's successful sign-in left the cooldown behind and made
    /// the next expiry wait it out for no reason.
    @Test func aUsersSuccessfulSignInClearsTheCooldown() {
        var policy = AutoReauthPolicy()
        let automatic = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(automatic)
        policy.finish(accountID: "a", succeeded: false, now: now)
        let user = policy.beginUserInitiated(accountID: "a")
        #expect(user)
        policy.finish(accountID: "a", succeeded: true, now: now)
        let nextExpiry = policy.begin(
            accountID: "a", isApplicationActive: true, now: now.addingTimeInterval(1)
        )
        #expect(nextExpiry)
    }

    /// P9b (audit N1): an AUTOMATIC attempt starts the cooldown whatever its
    /// outcome. A 401 that keeps escalating without the `invalid_token`
    /// challenge (no latch, so the socket and the sync loop raise the banner
    /// again right after every successful flash) must not reopen the consent
    /// window on every escalation. Fails on the pre-P9b policy, where a success
    /// cleared the cooldown.
    @Test func aSuccessfulAutomaticAttemptStillStartsTheCooldown() {
        var policy = AutoReauthPolicy()
        let first = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(first)
        policy.finish(accountID: "a", succeeded: true, now: now)

        let justInside = now.addingTimeInterval(AutoReauthPolicy.retryInterval - 1)
        let again = policy.begin(accountID: "a", isApplicationActive: true, now: justInside)
        #expect(again == false, "a successful automatic attempt let the next escalation reopen the window")
        // The user's own Sign In is never rate-limited.
        let user = policy.beginUserInitiated(accountID: "a")
        #expect(user)
        policy.finish(accountID: "a", succeeded: false, now: justInside)

        let after = justInside.addingTimeInterval(AutoReauthPolicy.retryInterval)
        let allowed = policy.begin(accountID: "a", isApplicationActive: true, now: after)
        #expect(allowed)
    }

    /// P9b: a heal (re-install onto a grant another process stored) is bounded
    /// to one per interval per account — two processes sharing one dead
    /// session would otherwise re-install each other on every activation — and
    /// is independent of the consent cooldown, which a legitimate heal usually
    /// follows. Fails if heals are unbounded, share the consent cooldown, or
    /// survive a sign-out.
    @Test func healsAreBoundedPerIntervalAndIndependentOfTheConsentCooldown() {
        var policy = AutoReauthPolicy()
        let attempt = policy.begin(accountID: "a", isApplicationActive: true, now: now)
        #expect(attempt)
        policy.finish(accountID: "a", succeeded: false, now: now)
        #expect(policy.allowsHeal(accountID: "a", now: now), "a failed consent attempt blocked the heal")

        policy.recordHeal(accountID: "a", now: now)
        #expect(policy.allowsHeal(accountID: "a", now: now.addingTimeInterval(AutoReauthPolicy.retryInterval - 1)) == false)
        #expect(policy.allowsHeal(accountID: "b", now: now))
        #expect(policy.allowsHeal(accountID: "a", now: now.addingTimeInterval(AutoReauthPolicy.retryInterval)))

        policy.recordHeal(accountID: "a", now: now)
        policy.forget(accountID: "a")
        #expect(policy.allowsHeal(accountID: "a", now: now))
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
