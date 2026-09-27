import Foundation
import HeraldKit

/// Decides whether Herald may re-run consent for an account BY ITSELF, without
/// the user pressing the re-auth banner's button.
///
/// The re-auth Herald can automate is not silent: `ASWebAuthenticationSession`
/// always shows a window, and it only completes instantly because the HQBase web
/// session behind it is still alive (see ``WebAuthenticationPresenter``). So the
/// automatic attempt is a *flash*, and every rule here exists to make sure the
/// user never gets that flash at a moment they did not ask for:
///
/// - only while Herald is the frontmost app — a window stealing focus out of
///   another app is worse than a banner waiting to be clicked;
/// - at most one attempt in flight per account, so a burst of failed passes
///   cannot open a second window over the first;
/// - at most one AUTOMATIC attempt per ``retryInterval`` per account, whatever
///   the last one's outcome — the banner is the fallback and must not turn into
///   a window that reopens every poll. Outcome-independent since P9b (audit N1):
///   a success used to clear the cooldown, and a 401 that keeps escalating
///   WITHOUT the `invalid_token` challenge (so no latch; the socket and the sync
///   loop still raise the banner) re-fired the consent window after every
///   successful flash. A user's own attempt is not rate-limited, and only its
///   failure (or Cancel) starts the cooldown.
///
/// A value type with no dependencies: the whole decision is testable without a
/// browser, an account, or a clock.
struct AutoReauthPolicy {
    /// How long an automatic attempt (of any outcome), or a failed or cancelled
    /// attempt of the user's, suppresses the next automatic one for that account. Longer than any sync cadence, so the poll loop cannot
    /// walk the app into a second window; short enough that a user who fixed
    /// their web session in the browser gets picked up without relaunching.
    static let retryInterval: TimeInterval = 10 * 60

    /// The attempt running per account, and whether Herald started it by itself.
    private var inFlight: [Account.ID: Bool] = [:]
    /// When the account's cooldown started: the end of its last AUTOMATIC
    /// attempt (any outcome), or of a user attempt that did not resolve the
    /// expiry. A user's SUCCESSFUL sign-in clears it — the person fixed it, and
    /// a later expiry is a new event that deserves its own immediate attempt.
    /// An automatic success does NOT: it cannot tell a real repair from a
    /// server that will refuse the fresh grant again a moment later.
    private var cooldownStart: [Account.ID: Date] = [:]

    /// Whether an automatic attempt for `accountID` is allowed right now.
    ///
    /// Pure: call ``begin(accountID:)`` to actually claim the attempt.
    func allowsAttempt(
        accountID: Account.ID,
        isApplicationActive: Bool,
        now: Date = .now
    ) -> Bool {
        guard isApplicationActive else { return false }
        guard inFlight[accountID] == nil else { return false }
        guard let last = cooldownStart[accountID] else { return true }
        return now.timeIntervalSince(last) >= Self.retryInterval
    }

    /// Claims an attempt for `accountID`, returning `false` when the rules say no
    /// — so the caller cannot check and claim in two steps that something else
    /// could slip between.
    mutating func begin(
        accountID: Account.ID,
        isApplicationActive: Bool,
        now: Date = .now
    ) -> Bool {
        guard allowsAttempt(accountID: accountID, isApplicationActive: isApplicationActive, now: now)
        else { return false }
        inFlight[accountID] = true
        return true
    }

    /// Claims an attempt the USER asked for. The frontmost rule and the cooldown
    /// do not apply — they exist to protect the user from windows they did not
    /// ask for — but the one-at-a-time rule still does: a click while an
    /// automatic attempt is running must not open a second window.
    mutating func beginUserInitiated(accountID: Account.ID) -> Bool {
        guard inFlight[accountID] == nil else { return false }
        inFlight[accountID] = false
        return true
    }

    /// Records how the claimed attempt ended. An automatic attempt starts the
    /// cooldown whatever its outcome; a user's attempt starts it unless it
    /// `succeeded`, in which case the cooldown is cleared.
    ///
    /// A no-op when the attempt was already abandoned by ``forget(accountID:)``
    /// (a sign-out mid-attempt): the account's slate was deliberately wiped, and
    /// writing a cooldown for it here would be the dead session's cooldown
    /// surviving into the next sign-in.
    mutating func finish(accountID: Account.ID, succeeded: Bool, now: Date = .now) {
        guard let isAutomatic = inFlight.removeValue(forKey: accountID) else { return }
        if succeeded, !isAutomatic {
            cooldownStart[accountID] = nil
        } else {
            cooldownStart[accountID] = now
        }
    }

    // MARK: - Heals (P9b)

    /// When the account was last re-installed WITHOUT consent because a
    /// different grant turned up in the store (another Herald process signed
    /// in). Separate from the consent cooldown: a legitimate heal usually comes
    /// right after a failed or cancelled consent attempt, and must not wait
    /// that out. Bounded by the same ``retryInterval``: two processes sharing
    /// one dead session each see the other's refresh as "a different grant",
    /// and without a bound they would re-install each other on every
    /// activation.
    private var lastHeal: [Account.ID: Date] = [:]

    /// Whether a heal (a re-install onto a grant somebody else stored) is
    /// allowed for this account now.
    func allowsHeal(accountID: Account.ID, now: Date = .now) -> Bool {
        guard let last = lastHeal[accountID] else { return true }
        return now.timeIntervalSince(last) >= Self.retryInterval
    }

    /// Records a heal, starting its interval.
    mutating func recordHeal(accountID: Account.ID, now: Date = .now) {
        lastHeal[accountID] = now
    }

    /// Whether an automatic attempt is running for this account — what the banner
    /// reads to say "Signing you back in…" instead of offering a button that
    /// would open a second window.
    func isAttempting(accountID: Account.ID) -> Bool { inFlight[accountID] != nil }

    /// Drops everything remembered about an account. Signing out and back in must
    /// not inherit the cooldown of the session that died.
    mutating func forget(accountID: Account.ID) {
        inFlight[accountID] = nil
        cooldownStart[accountID] = nil
        lastHeal[accountID] = nil
    }
}
