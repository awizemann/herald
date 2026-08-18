import Foundation
import Testing

@testable import HeraldKit

/// Records what would have been shown, so the decision logic is assertable
/// without `UNUserNotificationCenter` (a real bundle, and a prompt at a human).
private actor RecordingCenter: NewMailNotificationPosting {
    private(set) var posted: [NewMailNotification] = []
    private(set) var authorizationRequests = 0
    private let grants: Bool

    init(grants: Bool = true) { self.grants = grants }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return grants
    }

    func post(_ notification: NewMailNotification) async {
        posted.append(notification)
    }
}

private struct StubLookup: NewMailMessageLookup {
    var messages: [String: MessageSummary] = [:]

    func message(id: String, accountID: String) async throws -> MessageSummary? {
        messages[id]
    }
}

private func makeMessage(
    id: String,
    thread: String = "thr_1",
    direction: MessageDirection = .inbound,
    folder: MailFolder = .inbox,
    read: Bool = false,
    from: String = "Ada Lovelace <ada@example.net>",
    subject: String = "Invoice question",
    snippet: String = "About invoice 4471…",
    received: Date = Date(timeIntervalSince1970: 1_000)
) -> MessageSummary {
    MessageSummary(
        id: id,
        threadID: thread,
        mailboxID: "mbx",
        direction: direction,
        folder: folder,
        fromAddress: from,
        to: ["support@example.com"],
        subject: subject,
        snippet: snippet,
        receivedAt: received,
        sentAt: nil,
        readAt: read ? Date(timeIntervalSince1970: 2_000) : nil,
        starredAt: nil,
        hasAttachments: false,
        createdAt: received
    )
}

@Suite("New-mail notifications")
struct NewMailNotifierTests {
    /// Fails if the bootstrap flag is ignored: signing in reports the entire
    /// existing inbox as inserted, and the user would be buried in banners for
    /// mail they read last week.
    @Test func bootstrapPassIsSilent() async {
        let center = RecordingCenter()
        let lookup = StubLookup(messages: ["m1": makeMessage(id: "m1")])
        let notifier = NewMailNotifier(center: center, lookup: lookup)

        await notifier.handle(
            ChangeSet(inserted: ["m1"], isBootstrap: true),
            accountID: "acc",
            accountLabel: "Work"
        )

        #expect(await center.posted.isEmpty)
        // Not even the permission prompt: nothing was going to be posted.
        #expect(await center.authorizationRequests == 0)
    }

    /// Fails if any of the three filters is dropped — an outbound copy of what
    /// the user just sent, a message already read elsewhere, or mail delivered
    /// straight into archive must all be silent.
    @Test func onlyInboundUnreadInboxMailNotifies() async {
        let center = RecordingCenter()
        let lookup = StubLookup(messages: [
            "sent": makeMessage(id: "sent", direction: .outbound),
            "read": makeMessage(id: "read", read: true),
            "archived": makeMessage(id: "archived", folder: .archived),
            "new": makeMessage(id: "new", thread: "thr_new"),
        ])
        let notifier = NewMailNotifier(center: center, lookup: lookup)

        await notifier.handle(
            ChangeSet(inserted: ["sent", "read", "archived", "new"]),
            accountID: "acc",
            accountLabel: "Work"
        )

        let posted = await center.posted
        #expect(posted.count == 1)
        #expect(posted.first?.messageID == "new")
        #expect(posted.first?.threadID == "thr_new")
    }

    /// Fails if a burst is posted message-by-message: five arrivals in one poll
    /// must be ONE banner carrying the count, not five stacked banners.
    @Test func aBurstCoalescesIntoOneNotification() async {
        let center = RecordingCenter()
        var messages: [String: MessageSummary] = [:]
        for index in 0..<5 {
            messages["m\(index)"] = makeMessage(id: "m\(index)", thread: "thr_\(index)")
        }
        let notifier = NewMailNotifier(center: center, lookup: StubLookup(messages: messages), coalesceThreshold: 3)

        await notifier.handle(
            ChangeSet(inserted: Set(messages.keys)),
            accountID: "acc",
            accountLabel: "Work"
        )

        let posted = await center.posted
        #expect(posted.count == 1)
        #expect(posted.first?.isCoalesced == true)
        #expect(posted.first?.messageCount == 5)
        #expect(posted.first?.body == "5 new messages")
        // A coalesced banner cannot name one conversation, so it must not
        // pretend to: clicking it may only select the account.
        #expect(posted.first?.threadID == nil)
    }

    /// Fails if the threshold is off by one: a handful of arrivals keeps its
    /// per-message banners, which are the only ones a click can route.
    @Test func aSmallBatchKeepsPerMessageBanners() async {
        let center = RecordingCenter()
        let messages = [
            "m1": makeMessage(id: "m1", thread: "t1", received: Date(timeIntervalSince1970: 10)),
            "m2": makeMessage(id: "m2", thread: "t2", received: Date(timeIntervalSince1970: 20)),
        ]
        let notifier = NewMailNotifier(center: center, lookup: StubLookup(messages: messages), coalesceThreshold: 3)

        await notifier.handle(ChangeSet(inserted: ["m1", "m2"]), accountID: "acc", accountLabel: "Work")

        let posted = await center.posted
        #expect(posted.count == 2)
        // Newest last, so it is the banner left on screen.
        #expect(posted.last?.messageID == "m2")
        #expect(Set(posted.map(\.threadID)) == ["t1", "t2"])
    }

    /// Fails if the "already announced" history is dropped: the same message id
    /// reappearing in a later pass (a re-upsert, a move back into the inbox)
    /// must not be announced twice.
    @Test func aRepeatedInsertionIsNotAnnouncedTwice() async {
        let center = RecordingCenter()
        let lookup = StubLookup(messages: ["m1": makeMessage(id: "m1")])
        let notifier = NewMailNotifier(center: center, lookup: lookup)

        await notifier.handle(ChangeSet(inserted: ["m1"]), accountID: "acc", accountLabel: "Work")
        await notifier.handle(ChangeSet(inserted: ["m1"]), accountID: "acc", accountLabel: "Work")

        #expect(await center.posted.count == 1)
    }

    /// Fails if a denial is treated as a retryable error: the system prompts
    /// once, and asking again on every 15-second poll is pointless work.
    @Test func aDeniedAuthorizationIsAskedForOnlyOnce() async {
        let center = RecordingCenter(grants: false)
        let lookup = StubLookup(messages: [
            "m1": makeMessage(id: "m1"),
            "m2": makeMessage(id: "m2", thread: "t2"),
        ])
        let notifier = NewMailNotifier(center: center, lookup: lookup)

        await notifier.handle(ChangeSet(inserted: ["m1"]), accountID: "acc", accountLabel: "Work")
        await notifier.handle(ChangeSet(inserted: ["m2"]), accountID: "acc", accountLabel: "Work")

        #expect(await center.authorizationRequests == 1)
        #expect(await center.posted.isEmpty)
    }

    /// Fails if `updated` ids are treated as arrivals — marking a message read
    /// on the web is an update, and must never raise a banner.
    @Test func anUpdateIsNotAnArrival() async {
        let center = RecordingCenter()
        let lookup = StubLookup(messages: ["m1": makeMessage(id: "m1")])
        let notifier = NewMailNotifier(center: center, lookup: lookup)

        await notifier.handle(ChangeSet(updated: ["m1"]), accountID: "acc", accountLabel: "Work")

        #expect(await center.posted.isEmpty)
    }

    /// Fails if the click payload loses the ids: the round trip through
    /// `userInfo` is what makes a banner routable at all.
    @Test func theClickPayloadRoundTrips() {
        let notification = NewMailNotification(
            id: "n",
            title: "Ada",
            subtitle: "Subject",
            body: "Snippet",
            accountID: "acc",
            threadID: "thr",
            messageID: "msg",
            messageCount: 1
        )
        let route = NewMailNotification.route(from: notification.userInfo)
        #expect(route == NewMailRoute(accountID: "acc", threadID: "thr", messageID: "msg"))
        // A payload from someone else's notification is not ours to route.
        #expect(NewMailNotification.route(from: ["other": "value"]) == nil)
    }

    /// Fails if the raw From header is shown: `"Ada" <ada@…>` in a banner title
    /// is what the address book exists to avoid.
    @Test func theSenderNameIsDisplayed() {
        #expect(NewMailNotifier.senderDisplayName("Ada Lovelace <ada@example.net>") == "Ada Lovelace")
        #expect(NewMailNotifier.senderDisplayName("\"Ada Lovelace\" <ada@example.net>") == "Ada Lovelace")
        #expect(NewMailNotifier.senderDisplayName("<ada@example.net>") == "ada@example.net")
        #expect(NewMailNotifier.senderDisplayName("ada@example.net") == "ada@example.net")
    }

    /// Fails if a pass bigger than the lookup budget claims an exact count it
    /// never resolved.
    @Test func anOversizedPassReportsAFloor() async {
        let center = RecordingCenter()
        var messages: [String: MessageSummary] = [:]
        for index in 0..<10 { messages["m\(index)"] = makeMessage(id: "m\(index)", thread: "t\(index)") }
        let notifier = NewMailNotifier(
            center: center,
            lookup: StubLookup(messages: messages),
            coalesceThreshold: 3,
            maxLookups: 4
        )

        await notifier.handle(ChangeSet(inserted: Set(messages.keys)), accountID: "acc", accountLabel: "Work")

        let posted = await center.posted
        #expect(posted.count == 1)
        #expect(posted.first?.body == "4+ new messages")
        #expect(posted.first?.title == "Work")
    }
}
