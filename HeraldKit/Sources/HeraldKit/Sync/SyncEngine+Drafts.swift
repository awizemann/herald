import Foundation
import OSLog

/// Same subsystem and category as `SyncEngine.swift`: the drafts poll is part of
/// the sync loop and its lines belong in the same stream. A file-scope
/// `private nonisolated let logger` per file is the project's rule, and the name
/// being file-local is exactly why the two do not collide.
private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SyncEngine")

/// The DRAFTS half of a sync pass: its own cadence, its own failure mode, and
/// never able to fail the mail pass.
///
/// A pure extraction from `SyncEngine.swift` — no behaviour change. What could
/// not come with it is `draftlessAccounts`: Swift does not allow stored
/// properties in an extension, so it stays on the actor beside the other
/// per-session capability sets. Members these methods reach for that used to be
/// `private` are internal now for the same reason — `private` is file-scoped and
/// this is another file. They are still HeraldKit-internal, so nothing outside
/// the module (the app included) can see them.
extension SyncEngine {
    /// Polls and reconciles the drafts list when its own interval has elapsed.
    ///
    /// Never throws: a drafts failure is not a sync failure (see above). It also
    /// never advances `lastDraftPoll` on failure, so a transient error is retried
    /// on the next pass rather than sat out for the whole interval.
    func syncDraftsIfDue(accountID: String) async {
        guard !draftlessAccounts.contains(accountID), isDraftPollDue else { return }
        do {
            let listed = try await api.listDrafts()
            try checkPassIsCurrent()
            let changes = try await store.reconcileDrafts(listed, accountID: accountID)
            lastDraftPoll = .now
            if !changes.isEmpty { emit(.draftsChanged(changes)) }
        } catch let error as MailAPIError where error == .unauthorized || Self.isScopeRefusal(error) {
            logger.warning("Drafts unavailable for this account (\(error.logCode, privacy: .public)); not polling them again this session")
            draftlessAccounts.insert(accountID)
        } catch is CancellationError {
            // Torn down by stop(); nothing to report and nothing to record.
        } catch {
            logger.warning("Draft poll failed: \(((error as? MailAPIError)?.logCode ?? "unknown"), privacy: .public)")
        }
    }

    private var isDraftPollDue: Bool {
        guard let lastDraftPoll else { return true }
        return lastDraftPoll.duration(to: .now) >= draftPollInterval
    }

    /// Test seam: how many passes actually reached `GET /drafts`. It is what makes
    /// "the second pass did NOT re-poll drafts" assertable without a clock.
    var lastDraftPollInstant: ContinuousClock.Instant? { lastDraftPoll }

    /// How rarely the drafts list is re-polled. Drafts are the one surface with
    /// no delta at all — `GET /drafts` is a whole-list read with no pagination
    /// and no journal entry — so it is deliberately NOT on the 15s message
    /// cadence: a folder the user visits occasionally does not justify a third
    /// request on every active-cadence tick. Local edits write straight through
    /// to the cache (`MailStore.storeLocalDraft`), so the user's OWN drafts are
    /// never waiting on this; it only catches drafts written elsewhere.
    public static let defaultDraftPollInterval: Duration = .seconds(60)

    /// Asks for a pass that also re-reads the drafts list, whatever the draft
    /// interval says.
    ///
    /// Separate from ``refreshNow()`` on purpose: that one also fires after every
    /// archive and every trash, and putting a whole-list `GET /drafts` behind each
    /// triage keystroke is exactly the cost the interval exists to avoid. This is
    /// for the moments the user is actually asking about drafts — opening the
    /// Drafts folder, or pressing Refresh while looking at it.
    public func refreshDraftsNow() {
        lastDraftPoll = nil
        refreshNow()
    }
}
