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
/// - at most one attempt per ``retryInterval`` per account after an attempt that
///   did not fix anything (cancelled, or failed) — the banner is the fallback and
///   must not turn into a window that reopens every poll.
///
/// A value type with no dependencies: the whole decision is testable without a
/// browser, an account, or a clock.
struct AutoReauthPolicy {
    /// How long a failed or cancelled automatic attempt suppresses the next one
    /// for that account. Longer than any sync cadence, so the poll loop cannot
    /// walk the app into a second window; short enough that a user who fixed
    /// their web session in the browser gets picked up without relaunching.
    static let retryInterval: TimeInterval = 10 * 60

    private var inFlight: Set<Account.ID> = []
    /// Last attempt that did NOT resolve the expiry, per account. A success
    /// clears the entry: the account is signed in again, and a *later* expiry is
    /// a new event that deserves its own immediate attempt.
    private var lastUnsuccessfulAttempt: [Account.ID: Date] = [:]

    /// Whether an automatic attempt for `accountID` is allowed right now.
    ///
    /// Pure: call ``begin(accountID:)`` to actually claim the attempt.
    func allowsAttempt(
        accountID: Account.ID,
        isApplicationActive: Bool,
        now: Date = .now
    ) -> Bool {
        guard isApplicationActive else { return false }
        guard !inFlight.contains(accountID) else { return false }
        guard let last = lastUnsuccessfulAttempt[accountID] else { return true }
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
        inFlight.insert(accountID)
        return true
    }

    /// Claims an attempt the USER asked for. The frontmost rule and the cooldown
    /// do not apply — they exist to protect the user from windows they did not
    /// ask for — but the one-at-a-time rule still does: a click while an
    /// automatic attempt is running must not open a second window.
    mutating func beginUserInitiated(accountID: Account.ID) -> Bool {
        guard !inFlight.contains(accountID) else { return false }
        inFlight.insert(accountID)
        return true
    }

    /// Records how the claimed attempt ended. `succeeded` clears the account's
    /// cooldown; anything else starts it.
    ///
    /// A no-op when the attempt was already abandoned by ``forget(accountID:)``
    /// (a sign-out mid-attempt): the account's slate was deliberately wiped, and
    /// writing a cooldown for it here would be the dead session's cooldown
    /// surviving into the next sign-in.
    mutating func finish(accountID: Account.ID, succeeded: Bool, now: Date = .now) {
        guard inFlight.remove(accountID) != nil else { return }
        if succeeded {
            lastUnsuccessfulAttempt[accountID] = nil
        } else {
            lastUnsuccessfulAttempt[accountID] = now
        }
    }

    /// Whether an automatic attempt is running for this account — what the banner
    /// reads to say "Signing you back in…" instead of offering a button that
    /// would open a second window.
    func isAttempting(accountID: Account.ID) -> Bool { inFlight.contains(accountID) }

    /// Drops everything remembered about an account. Signing out and back in must
    /// not inherit the cooldown of the session that died.
    mutating func forget(accountID: Account.ID) {
        inFlight.remove(accountID)
        lastUnsuccessfulAttempt[accountID] = nil
    }
}
