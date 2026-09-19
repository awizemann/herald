import Foundation
import HeraldKit

/// Compose-window plumbing: resolving a request into a session, vending that
/// session's view-model, and tearing both down. Split out of
/// `AppEnvironment.swift` verbatim; `composeSessions` stays on the main
/// declaration because an extension cannot hold stored properties.
extension AppEnvironment {
    // MARK: - Compose

    /// Resolves a compose request into a context and returns the id the compose
    /// window should be opened with. `nil` means there is nothing to compose
    /// (no account yet, or the message could not be loaded).
    func prepareCompose(_ request: ComposeRequest) async -> ComposeRequest.ID? {
        guard let graph = selectedGraph else { return nil }
        guard let context = await graph.mail.composeContext(for: request),
              // The account can be signed out inside that fetch; a session with
              // no graph behind it can never build a composer, and never be
              // released either.
              isCurrent(graph)
        else { return nil }
        composeSessions[request.id] = ComposeSession(accountID: graph.account.id, context: context)
        return request.id
    }

    /// The window's view-model: the same instance for the same request id, for as
    /// long as that composer is open, and always wired to the `OutboxService` of
    /// the account it was opened from. A closed composer is not resurrected — the
    /// window shows "no longer available" rather than a copy of a sent message.
    func makeComposeViewModel(id: ComposeRequest.ID) -> ComposeViewModel? {
        guard var session = composeSessions[id] else { return nil }
        if let existing = session.model {
            guard existing.isClosed else { return existing }
            releaseComposeViewModel(id: id)
            return nil
        }
        guard let outbox = graphs[session.accountID]?.outbox else { return nil }
        let accountID = session.accountID
        let model = ComposeViewModel(context: session.context, outbox: outbox, record: recordUsage, draftCache: { [weak self] event in
            // Routed to the account the composer was OPENED from — the same one
            // whose `outbox` is saving the draft — never to whichever account the
            // window happens to be showing: switching accounts with a composer up
            // would otherwise file the draft in the wrong account's folder.
            // Looked up fresh each time, because a composer can outlive its graph
            // (sign-out with a window open), and the event then belongs to nobody.
            guard let mail = self?.graphs[accountID]?.mail else { return }
            Task { await mail.applyDraftCacheEvent(event) }
        })
        session.model = model
        composeSessions[id] = session
        return model
    }

    /// The account a composer sends through. Test seam: the binding is otherwise
    /// only observable by watching which server the draft lands on.
    func composeAccountID(for id: ComposeRequest.ID) -> Account.ID? {
        composeSessions[id]?.accountID
    }

    /// Called when a compose window goes away. Drops the composer ONLY if it
    /// really is closed: a window that is merely being rebuilt must find its
    /// view-model — with its unsaved text — still here.
    func releaseComposeViewModel(id: ComposeRequest.ID) {
        guard composeSessions[id]?.model?.isClosed ?? false else { return }
        composeSessions[id] = nil
    }

    /// Signing an account out takes its compose windows' view-models with it —
    /// their `OutboxService` is gone, so leaving them alive leaves autosave tasks
    /// running against a server the app no longer has a token for.
    func closeComposeSessions(accountID: Account.ID) {
        for (id, session) in composeSessions where session.accountID == accountID {
            session.model?.stop()
            composeSessions[id] = nil
        }
    }

    func setWindowActive(_ active: Bool) async {
        // EVERY account follows the app's activation: an account the window is
        // not showing still has to notice new mail at the active cadence, or its
        // unread count goes stale until the user switches to it.
        //
        // A snapshot on purpose — an account signed out mid-loop just gets a
        // cadence change on a stopped engine, and one installed mid-loop seeds
        // its own cadence in `install`.
        for graph in Array(graphs.values) { await graph.mail.setActive(active) }
        // Herald coming to the front is the moment a deferred automatic re-auth
        // becomes allowed: the session almost always dies while the user is
        // somewhere else, and the sync pass that noticed announced it once.
        if active { await retryAutomaticReauthentication() }
    }
}
