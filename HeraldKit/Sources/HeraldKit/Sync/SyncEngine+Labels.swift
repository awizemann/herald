import Foundation
import OSLog

/// See `SyncEngine+Drafts.swift` for why the category is shared with the engine.
private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "SyncEngine")

/// The LABEL half of a sync pass: the label list, and behind it the membership
/// reconciliation that upstream 1.4.2's embedded row labels demoted from
/// "the only source" to "the backstop".
///
/// A pure extraction from `SyncEngine.swift` — no behaviour change. The stored
/// properties this code owns (`labellessAccounts`, `labelCapableAccounts`,
/// `labelAssignmentWrites`, `lastSweepDigests`, `labelEmbeddingAccounts`) stay
/// on the actor, because an extension cannot declare storage; members that used
/// to be `private` are internal so this file can reach them, and no wider.
extension SyncEngine {
    /// Reconciles the label list and, behind it, label membership.
    ///
    /// Two halves, in order:
    /// 1. `GET /labels` — the workspace's labels (shared, not per-user), replacing
    ///    the cached list wholesale. A label the server no longer lists takes its
    ///    assignments with it.
    /// 2. one `GET /messages?labelId=…` page-walk PER label. A walk that hits the
    ///    page cap does NOT write: `replaceAssignments` is authoritative by
    ///    construction, so a truncated listing would erase the assignments the
    ///    server had not got round to returning.
    ///
    /// WHAT THIS IS FOR HAS CHANGED. Against a server that embeds labels on
    /// message rows (1.4.2+) half 2 is no longer the membership source — the rows
    /// are, written by ``MailStore/applyEmbeddedLabels(from:accountID:)`` on every
    /// upsert — and this runs rarely, as the reconciliation for what rows cannot
    /// say: a label deleted workspace-wide, and messages in folders this cache has
    /// never listed. Against an older server it is still the ONLY source and still
    /// runs on ``defaultLabelPollInterval``. Which of the two applies is decided
    /// per account, by response shape, in ``labelEmbeddingAccounts``.
    ///
    /// Never throws: a label failure is not a sync failure, and `lastLabelPoll` is
    /// only advanced on success so a transient error retries next pass.
    func syncLabelsIfDue(accountID: String) async {
        guard !labellessAccounts.contains(accountID), isLabelPollDue else { return }
        // The CAPABILITY probe is `GET /labels` and nothing else. A refusal from
        // one label's message listing says something about that listing, not
        // about whether this server has labels at all — folding the two together
        // let a single 403 disable the whole feature for the session.
        let labels: [MailLabel]
        do {
            labels = try await api.listLabels()
            labelCapableAccounts.insert(accountID)
        } catch let error as MailAPIError
            where error == .unauthorized
            || Self.isScopeRefusal(error)
            || (error == .notFound && !labelCapableAccounts.contains(accountID)) {
            logger.warning("Labels unavailable for this account (\(error.logCode, privacy: .public)); not sweeping them again this session")
            labellessAccounts.insert(accountID)
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Label list failed: \(((error as? MailAPIError)?.logCode ?? "unknown"), privacy: .public)")
            return
        }

        // Whatever happens to the membership walks below, the writes that DID
        // land have to be announced — a later label throwing must not make the
        // earlier ones invisible until the next sweep.
        var changed = false
        defer { if changed { emit(.labelsChanged) } }
        do {
            try checkPassIsCurrent()
            changed = try await store.replaceLabels(labels, accountID: accountID)
        } catch {
            logger.warning("Label list could not be cached: \(error.localizedDescription, privacy: .private)")
            return
        }
        // A CHANGE TO THE LABEL LIST FORCES A FULL RECONCILIATION. It is the one
        // event rows cannot describe: a deleted label never touches a message, so
        // no upsert mentions it and the digests still describe a membership the
        // workspace has dismantled. Renames and creations come through here too
        // and cost nothing extra — the list only moves when a human moved it.
        if changed { lastSweepDigests.removeAll() }

        var swept = 0
        for label in labels {
            do {
                try checkPassIsCurrent()
                // A nil walk is a deliberate SKIP, not a failure: it still counts
                // as swept, or a label that is permanently page-capped would keep
                // the interval from ever restarting and re-sweep every pass. A
                // walk (or write) that THROWS must not count — counting it would
                // restart the interval on a partial sweep and sit the failed
                // label out instead of retrying it next pass.
                guard let rows = try await labelMembership(label.id, accountID: accountID) else {
                    swept += 1
                    continue
                }
                // The walk already cost its requests; what this skips is the
                // store work — a fetch, a dictionary build and a row diff per
                // label — for a membership identical to the one this engine last
                // wrote. See ``lastSweepDigests`` for why that is safe.
                let digest = SweepDigest(rows)
                guard lastSweepDigests[label.id] != digest else {
                    swept += 1
                    continue
                }
                labelAssignmentWrites += 1
                changed = try await store.replaceAssignments(
                    labelID: label.id, messages: rows, accountID: accountID
                ) || changed
                // Only after the write actually landed: a throw above must leave
                // the digest as it was, or the retry would skip the write too.
                lastSweepDigests[label.id] = digest
                swept += 1
            } catch is CancellationError {
                return
            } catch {
                // Transient for THIS label; the others are still worth sweeping.
                logger.warning(
                    "Label membership failed for one label (\(((error as? MailAPIError)?.logCode ?? "unknown"), privacy: .public))"
                )
            }
        }
        // A label the workspace deleted takes its assignments with it
        // (`replaceLabels`), so its digest would otherwise describe rows that no
        // longer exist if the id were ever reused.
        let live = Set(labels.map(\.id))
        lastSweepDigests = lastSweepDigests.filter { live.contains($0.key) }
        // The interval only restarts on a sweep that actually covered every
        // label; a partial one is retried on the next pass rather than sat out.
        if swept == labels.count { lastLabelPoll = .now }
    }

    /// Every message carrying one label, or `nil` when the walk could not be
    /// completed and the caller must not treat it as a full listing.
    private func labelMembership(_ labelID: String, accountID: String) async throws -> [LabelRowKey]? {
        var rows: [LabelRowKey] = []
        var cursor: String?
        var pages = 0
        while pages < maxMessagePages {
            try checkPassIsCurrent()
            let page = try await api.listMessages(
                labelID: labelID, limit: Self.messagePageLimit, cursor: cursor
            )
            pages += 1
            rows.append(contentsOf: page.messages.map {
                LabelRowKey(messageID: $0.id, threadID: $0.threadID)
            })
            guard let next = page.nextCursor else {
                // A pre-pagination server has no `Link` header at all and caps the
                // response silently, so a full-cap page may be truncated — the same
                // rule `syncMessages` follows before it tombstones.
                guard page.messages.count < Self.serverMessageListCap || paginatingAccounts.contains(accountID) else {
                    logger.warning("Label membership hit the pre-pagination server cap; leaving the cached assignments alone")
                    return nil
                }
                return rows
            }
            cursor = next
        }
        logger.warning(
            "Label membership page cap (\(self.maxMessagePages, privacy: .public)) hit for one label; leaving its cached assignments alone"
        )
        return nil
    }

    private var isLabelPollDue: Bool {
        guard let lastLabelPoll else { return true }
        return lastLabelPoll.duration(to: .now) >= currentLabelPollInterval
    }

    /// The interval the label sweep is currently held to. Also the test seam for
    /// the gating, mirroring ``currentPollInterval``.
    ///
    /// Once the server is known to embed labels the on-screen surface stops
    /// mattering: membership rides in with the rows the pass is already fetching,
    /// so the sweep is only ever the slow reconciliation. Until then — and
    /// forever, on a pre-1.4.2 server — the legacy visible/idle pair applies.
    var currentLabelPollInterval: Duration {
        if serverEmbedsLabels { return reconciliationLabelPollInterval }
        return isLabelSurfaceVisible ? labelPollInterval : idleLabelPollInterval
    }

    /// Test seam, same purpose as ``lastDraftPollInstant``.
    var lastLabelPollInstant: ContinuousClock.Instant? { lastLabelPoll }

    /// LEGACY (pre-1.4.2 server) label sweep interval, while labels are on screen.
    ///
    /// Before upstream 1.4.2 labels were a surface with no delta at all: the v1
    /// change journal reported a label-only edit as an upsert of the message (the
    /// server bumps `messages.updated_at`), but the v1 payload carried no
    /// `labels` field, so the entry said "something about this message changed"
    /// and nothing about which labels it now has. Membership had to be re-derived
    /// by listing every label, one request each.
    ///
    /// Against a server that DOES embed labels this interval is not used at all —
    /// see ``defaultReconciliationLabelPollInterval``. It survives unchanged for
    /// 1.3.4/1.4.0 servers, which remain supported and for which it is still the
    /// only membership source there is.
    ///
    /// The user's OWN assignments never wait for it either way: they are written
    /// straight into the cache and settled from the server's
    /// `LabelAssignmentResult`.
    public static let defaultLabelPollInterval: Duration = .seconds(120)

    /// LEGACY (pre-1.4.2 server) label sweep interval while NOTHING on screen
    /// shows labels.
    ///
    /// 120s buys freshness for chips and badges the user can actually see. When
    /// the app is not frontmost — or the account has no labels at all — that
    /// freshness is bought for nobody, and on such a server the sweep is the
    /// single most expensive idle thing Herald does: one
    /// `GET /messages?labelId=` page-walk PER label, forever, whatever else is
    /// happening. Twelve and a half minutes is still far inside any session and
    /// cuts the idle request rate by ~6×.
    ///
    /// Deliberately not "never": on those servers the surface has no delta, so a
    /// sweep that stops entirely is a cache that diverges silently until the user
    /// next opens a label. And the moment the user DOES ask about labels,
    /// ``refreshLabelsNow()`` sweeps immediately regardless of any interval.
    public static let defaultIdleLabelPollInterval: Duration = .seconds(750)

    /// The sweep's interval once the server is known to EMBED labels on message
    /// rows (upstream 1.4.2's `includeLabels=true`).
    ///
    /// On such a server membership arrives with the rows themselves — every
    /// listing, every journal upsert, every action answer — so the sweep stops
    /// being the source of truth and becomes a RECONCILIATION. It is kept, and
    /// kept on a timer rather than retired, for exactly one thing rows cannot
    /// report: DELETING a label workspace-wide touches no message, so no row ever
    /// mentions it again and nothing in the journal says it is gone. The other
    /// two triggers are prompt — the `labels` wake frame and any change to the
    /// label LIST both force a full reconciliation — and this timer is the
    /// backstop for a frame that was dropped (they are best-effort and never
    /// replayed) or a socket that was never up.
    ///
    /// Half an hour: long enough that the per-label page-walks stop mattering as
    /// a cost at all, short enough that a divergence nobody notices is bounded.
    /// It deliberately does NOT vary with the on-screen label surface the way the
    /// legacy intervals do — at this rarity the distinction buys nothing.
    public static let defaultReconciliationLabelPollInterval: Duration = .seconds(1800)

    /// Records what a batch of summaries says about the server's label
    /// embedding, into ``SyncEngine/labelEmbeddingAccounts`` — the set of
    /// accounts whose server embeds label membership on message rows, which is
    /// what demotes the sweep to a reconciliation.
    ///
    /// HOW THE CAPABILITY IS DETECTED — deliberately by RESPONSE SHAPE, never by
    /// a version number (the spec's `info.version` is the API version and useless
    /// for this, and no capability endpoint exists): the FIRST `MessageSummary`
    /// this session whose `labels` is non-`nil` proves it. The client always asks
    /// (`includeLabels: true` in `AppEnvironment`); a server at 1.4.2 or newer
    /// answers with the key on every row — `[]` when the message has no labels,
    /// which is still a statement and still counts — and a server older than that
    /// ignores the parameter entirely and answers without it, so every row is
    /// `nil` and the flag is never set.
    ///
    /// Therefore `nil` is NEVER evidence of anything. A pass that upserted no
    /// messages at all, or one that ran before the first row arrived, simply
    /// leaves the account undetected and the legacy sweep cadence in force — the
    /// conservative direction: more requests, never a wrong cache.
    ///
    /// Per SESSION and per account, not persisted. The cache is rebuildable and a
    /// server can be downgraded between launches, so re-deciding from the first
    /// row of the first pass costs nothing and can never be stale. Cleared by
    /// ``start(accountID:)`` for the same reason.

    func noteLabelEmbedding(in summaries: [MessageSummary], accountID: String) {
        guard !labelEmbeddingAccounts.contains(accountID),
              summaries.contains(where: { $0.labels != nil })
        else { return }
        logger.info("Server embeds label membership on message rows; the per-label sweep is now a reconciliation")
        labelEmbeddingAccounts.insert(accountID)
    }

    /// Whether the CURRENT account's server embeds labels on message rows.
    var serverEmbedsLabels: Bool {
        guard let accountID else { return false }
        return labelEmbeddingAccounts.contains(accountID)
    }

    /// The digest ``SyncEngine/lastSweepDigests`` holds per label.
    ///
    /// `replaceAssignments` is a fetch, a dictionary build and a diff per label;
    /// on a membership that did not move it is all of that to write nothing. The
    /// digest turns the common case (a label nobody touched between two sweeps)
    /// into an integer compare.
    ///
    /// SAFE because it only ever suppresses a write that would have been a no-op
    /// AGAINST THE PREVIOUS SWEEP'S OWN OUTPUT. Two ways the store can hold
    /// something else: a local optimistic toggle, and the server's authoritative
    /// per-message answer — both of which are what the user just asked for, and
    /// both of which the NEXT sweep whose membership actually differs writes
    /// through. ``refreshLabelsNow()`` drops the digests outright, so the paths
    /// that mean "the user is asking about labels right now" (opening a label,
    /// Refresh inside one) always do the full authoritative write.
    /// A membership row set, cheaply. Order-independent (the server does not
    /// promise one) and carries the count alongside the hash so a hash collision
    /// alone cannot suppress a write.
    struct SweepDigest: Hashable {
        let count: Int
        let hash: Int

        init(_ rows: [LabelRowKey]) {
            let unique = Set(rows)
            self.count = unique.count
            self.hash = unique.hashValue
        }
    }

    /// Asks for a pass that also reconciles labels, whatever the label interval
    /// says. Three callers: opening a label in the sidebar, pressing Refresh while
    /// inside one, and the `labels` wake frame — which is the server announcing
    /// that a label was created, renamed or DELETED, the one change no message row
    /// can report.
    public func refreshLabelsNow() {
        lastLabelPoll = nil
        // This is the "the user is asking about labels RIGHT NOW" path, so it is
        // also the one that must not trust a digest: it forces the full
        // authoritative `replaceAssignments` for every label, which is how a
        // cache that drifted out of step with the server (a local write the
        // server never took, a sweep skipped over a race) is put right.
        lastSweepDigests.removeAll()
        refreshNow()
    }

    /// Tells the loop whether anything on screen is showing labels.
    ///
    /// LEGACY-SERVER SIGNAL ONLY. On a pre-1.4.2 server the sweep is one request
    /// PER LABEL and the dominant idle cost, so it runs at
    /// ``defaultLabelPollInterval`` only while the answer is worth having promptly
    /// and at ``defaultIdleLabelPollInterval`` otherwise. Once the server is known
    /// to embed labels on message rows this signal stops affecting anything: the
    /// sweep is then the rare reconciliation and membership comes in with the rows
    /// regardless of what is on screen. The view-model still pushes it — deciding
    /// which server it is talking to is the engine's job, not the UI's.
    ///
    /// Deliberately NOT wired to wake the loop when it flips true, unlike
    /// ``setWakeSocketConnected(_:)``: waking costs a whole mail pass, and the
    /// two moments that genuinely need labels NOW (opening a label listing,
    /// Refresh inside one) already call ``refreshLabelsNow()``, which wakes the
    /// loop AND forces the sweep. Turning the surface on merely shortens the
    /// interval the next wait computes.
    public func setLabelSurfaceVisible(_ visible: Bool) {
        isLabelSurfaceVisible = visible
    }
}
