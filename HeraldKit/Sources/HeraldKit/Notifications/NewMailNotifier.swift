import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "NewMailNotifier")

/// The one store read new-mail notifications need, behind a protocol so the
/// notifier is testable without SwiftData. ``MailStore`` conforms as-is.
public nonisolated protocol NewMailMessageLookup: Sendable {
    func message(id: String, accountID: String) async throws -> MessageSummary?
}

extension MailStore: NewMailMessageLookup {}

/// Decides what — if anything — a sync pass should show the user, and posts it.
///
/// An actor, not a `@MainActor` type: it is driven from the sync event stream and
/// its only mutable state (the "already told the user about this" history) must
/// not need the main actor. It is deliberately UI-free — everything about
/// `UNUserNotificationCenter` lives behind ``NewMailNotificationPosting`` in the
/// app target.
public actor NewMailNotifier {
    private let center: any NewMailNotificationPosting
    private let lookup: any NewMailMessageLookup
    /// More arrivals than this in one pass collapse into a single banner.
    private let coalesceThreshold: Int
    /// Cap on per-pass store reads. A pass with more insertions than this cannot
    /// be a handful of arrivals, so it is summarised from the reads we did do.
    private let maxLookups: Int

    /// `nil` until asked. Authorization is requested LAZILY — on the first pass
    /// that actually has something to say, or when the user turns the setting on
    /// — never at launch.
    private var authorization: Bool?

    /// Message ids already announced, newest last. Bounded: the process would
    /// otherwise accumulate one string per message for its whole life.
    private var announced: Set<String> = []
    private var announcedOrder: [String] = []
    private static let announcedLimit = 500

    public init(
        center: any NewMailNotificationPosting,
        lookup: any NewMailMessageLookup,
        coalesceThreshold: Int = 3,
        maxLookups: Int = 100
    ) {
        self.center = center
        self.lookup = lookup
        self.coalesceThreshold = coalesceThreshold
        self.maxLookups = maxLookups
    }

    // MARK: - Rules

    /// What earns a banner: inbound mail, still unread, sitting in the inbox.
    ///
    /// Anything the user sent (`outbound`), anything already read (marked read on
    /// the web, or by another device before the poll landed) and anything that
    /// arrived straight into archive/trash/sent/drafts is silent.
    public nonisolated static func isNotifiable(_ message: MessageSummary) -> Bool {
        message.direction == .inbound && message.isUnread && message.folder == .inbox
    }

    /// The pure half: candidates in, banners out. Empty means "say nothing".
    ///
    /// Up to `coalesceThreshold` arrivals each get their own banner (so a click
    /// can open the right conversation); a bigger burst collapses into ONE, which
    /// can only route to the account. `truncated` says the pass had more
    /// insertions than we resolved, so the count is a floor, not a total.
    public nonisolated static func notifications(
        for candidates: [MessageSummary],
        accountID: String,
        accountLabel: String,
        coalesceThreshold: Int,
        truncated: Bool = false
    ) -> [NewMailNotification] {
        guard !candidates.isEmpty else { return [] }
        // Newest first: the banner that lands last (and stays on screen) is the
        // most recent arrival.
        let sorted = candidates.sorted { $0.displayDate > $1.displayDate }
        guard truncated || sorted.count > coalesceThreshold else {
            return sorted.reversed().map { message in
                NewMailNotification(
                    id: "herald.newmail.\(accountID).\(message.id)",
                    title: senderDisplayName(message.fromAddress),
                    subtitle: message.subject.isEmpty ? "(No subject)" : message.subject,
                    body: message.snippet,
                    accountID: accountID,
                    threadID: message.threadID,
                    messageID: message.id,
                    messageCount: 1
                )
            }
        }
        // A burst: one banner, no per-message detail, and a count that admits to
        // being a floor when the pass was too big to resolve in full.
        let count = sorted.count
        return [
            NewMailNotification(
                id: "herald.newmail.\(accountID).burst",
                title: accountLabel.isEmpty ? "New mail" : accountLabel,
                subtitle: "",
                body: truncated ? "\(count)+ new messages" : "\(count) new messages",
                accountID: accountID,
                threadID: nil,
                messageID: nil,
                messageCount: count
            )
        ]
    }

    /// `"Ada Lovelace <ada@example.com>"` → `"Ada Lovelace"`; a bare address is
    /// shown as-is. The server sends the raw From header value.
    nonisolated static func senderDisplayName(_ fromAddress: String) -> String {
        let trimmed = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") else { return trimmed }
        let name = trimmed[trimmed.startIndex..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !name.isEmpty { return name }
        let address = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return String(address)
    }

    // MARK: - Driving

    /// Called for every `.changed` event of an account whose notifications are on.
    public func handle(_ changes: ChangeSet, accountID: String, accountLabel: String) async {
        // A bootstrap reports the whole existing mailbox as inserted; an update is
        // a state change (read, starred, moved), never an arrival.
        guard !changes.isBootstrap, !changes.inserted.isEmpty else { return }

        // Sorted so the truncation cut is deterministic rather than set order.
        let ids = changes.inserted.sorted()
        let resolvable = ids.prefix(maxLookups)
        let truncated = ids.count > maxLookups

        var candidates: [MessageSummary] = []
        for id in resolvable {
            guard !announced.contains(id) else { continue }
            let message: MessageSummary?
            do {
                message = try await lookup.message(id: id, accountID: accountID)
            } catch {
                logger.warning("New-mail lookup failed: \(error.localizedDescription, privacy: .private)")
                continue
            }
            // Not a message id at all (a mailbox row, a conversation row) — the
            // ChangeSet mixes every kind of row it touched.
            guard let message, Self.isNotifiable(message) else { continue }
            candidates.append(message)
        }
        guard !candidates.isEmpty else { return }

        // Recorded before posting: whatever the notification centre does with it,
        // these messages have been considered, and a later pass that touches them
        // again (a re-upsert, a folder move back) must not announce them twice.
        for message in candidates { remember(message.id) }

        let notifications = Self.notifications(
            for: candidates,
            accountID: accountID,
            accountLabel: accountLabel,
            coalesceThreshold: coalesceThreshold,
            truncated: truncated
        )
        guard !notifications.isEmpty, await ensureAuthorized() else { return }
        for notification in notifications { await center.post(notification) }
    }

    /// Asks once per launch, and remembers the answer. A denial is final for the
    /// session: the system will not re-prompt, and hammering it every poll is
    /// pointless work.
    @discardableResult
    public func ensureAuthorized() async -> Bool {
        if let authorization { return authorization }
        let granted = await center.requestAuthorization()
        authorization = granted
        if !granted { logger.info("Notification authorization not granted; staying silent") }
        return granted
    }

    private func remember(_ messageID: String) {
        guard announced.insert(messageID).inserted else { return }
        announcedOrder.append(messageID)
        guard announcedOrder.count > Self.announcedLimit else { return }
        let dropped = announcedOrder.removeFirst()
        announced.remove(dropped)
    }
}
