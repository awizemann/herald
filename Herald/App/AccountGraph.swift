import Foundation
import HeraldKit

/// One account's live object graph: everything built from that account's API
/// client, kept together so it can be started and torn down as a unit.
///
/// Every account has one of these for as long as it is signed in — including the
/// accounts the window is NOT showing, so their sync keeps running and their
/// unread counts stay live.
@MainActor
final class AccountGraph {
    let account: Account
    let sync: SyncEngine
    let mail: MailViewModel
    let outbox: OutboxService
    /// Settings ▸ Signatures' client. Per-account like everything else here: two
    /// accounts manage different signatures on different servers.
    let signatures: SignatureManagementService
    /// Per-account: its "already announced" history dies with the graph, so a
    /// sign-out and a fresh sign-in cannot silence the new account's first mail.
    let notifier: NewMailNotifier
    /// This account's `GET /events` wake socket, when it has one.
    let wake: MailEventSocket?

    init(
        account: Account,
        sync: SyncEngine,
        mail: MailViewModel,
        outbox: OutboxService,
        signatures: SignatureManagementService,
        notifier: NewMailNotifier,
        wake: MailEventSocket? = nil
    ) {
        self.account = account
        self.sync = sync
        self.mail = mail
        self.outbox = outbox
        self.signatures = signatures
        self.notifier = notifier
        self.wake = wake
    }

    /// `stopAndWait`, not `stop`: sign-out purges this account's rows immediately
    /// afterwards, and a pass still unwinding would write them back in behind the
    /// purge.
    func stop() async {
        mail.stop()
        // Before the engine: a socket still up would keep asking a stopping
        // engine for passes, and a superseded graph's socket left running is a
        // second connection against the server's three-per-user limit — the
        // server closes the OLDEST to make room, so a leak here would evict the
        // live account's socket.
        await wake?.stop()
        await sync.stopAndWait()
    }
}
