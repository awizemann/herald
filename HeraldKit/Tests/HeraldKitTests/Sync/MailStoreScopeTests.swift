import Foundation
import Testing
@testable import HeraldKit

/// The store half of the sidebar redesign's scope model: a listing scope is a
/// SET of mailbox ids (a domain, or "all domains" minus the excluded ones), not
/// one optional id. Every test runs against a real in-memory SwiftData
/// container, because the thing under test is whether `#Predicate` with a
/// captured `Set.contains` actually filters in the store on this toolchain —
/// compiling is not the same as working.
@Suite("MailStore scope sets")
struct MailStoreScopeTests {
    private static let account = SyncFixtures.account

    /// Three mailboxes, one inbox thread each, all unread.
    private static func threeMailboxStore() async throws -> MailStore {
        let store = try MailStore.inMemory()
        for (index, mailboxID) in ["mbx_a", "mbx_b", "mbx_c"].enumerated() {
            let row = SyncFixtures.conversation(
                threadID: "thr_\(mailboxID)", latestID: "msg_\(index)", mailboxID: mailboxID
            )
            _ = try await store.upsertConversations([row], accountID: account, mailboxID: mailboxID, folder: .inbox)
            _ = try await store.upsertMessages(
                [SyncFixtures.message("msg_\(index)", threadID: "thr_\(mailboxID)", mailboxID: mailboxID)],
                accountID: account
            )
        }
        return store
    }

    /// Fails if `Set.contains` inside `#Predicate` is ignored (every row back),
    /// inverted, or only honours the first element — each of which compiles.
    @Test("A mailbox set lists exactly the rows of its members")
    func setListsExactlyItsMembers() async throws {
        let store = try await Self.threeMailboxStore()

        let two = try await store.conversations(accountID: Self.account, mailboxIDs: ["mbx_a", "mbx_c"], folder: .inbox)
        #expect(Set(two.map(\.id)) == ["thr_mbx_a", "thr_mbx_c"])

        let one = try await store.conversations(accountID: Self.account, mailboxIDs: ["mbx_b"], folder: .inbox)
        #expect(one.map(\.id) == ["thr_mbx_b"])

        let all = try await store.conversations(accountID: Self.account, mailboxIDs: nil, folder: .inbox)
        #expect(all.count == 3, "nil is every mailbox")

        let none = try await store.conversations(accountID: Self.account, mailboxIDs: [], folder: .inbox)
        #expect(none.isEmpty, "an empty scope (a domain with no mailboxes left) lists nothing")
    }

    /// The badge and the change-feed check must agree with the listing they
    /// describe; fails if either ignores the set.
    @Test("Unread counts, the scope check and message pages honour the set")
    func countsAndChecksHonourTheSet() async throws {
        let store = try await Self.threeMailboxStore()

        #expect(try await store.unreadCount(accountID: Self.account, mailboxIDs: ["mbx_a", "mbx_b"]) == 2)
        #expect(try await store.unreadCount(accountID: Self.account, mailboxIDs: nil) == 3)
        #expect(try await store.unreadCount(accountID: Self.account, mailboxIDs: []) == 0)

        #expect(try await store.hasConversation(
            threadID: "thr_mbx_c", accountID: Self.account, mailboxIDs: ["mbx_b", "mbx_c"], folder: .inbox
        ))
        #expect(try await !store.hasConversation(
            threadID: "thr_mbx_c", accountID: Self.account, mailboxIDs: ["mbx_a", "mbx_b"], folder: .inbox
        ))
        #expect(try await store.hasConversation(
            threadID: "thr_mbx_c", accountID: Self.account, mailboxIDs: nil, folder: .inbox
        ))

        let messages = try await store.messages(accountID: Self.account, mailboxIDs: ["mbx_a", "mbx_b"], folder: .inbox)
        #expect(Set(messages.map(\.id)) == ["msg_0", "msg_1"])
    }

    /// An account can hold far more mailboxes than SQLite's historical 999
    /// bound-parameter ceiling, and "all domains except one" passes nearly all
    /// of them. Fails (throws) if the set is bound one parameter per id past the
    /// ceiling this toolchain's SQLite enforces.
    @Test("A very large mailbox set still fetches")
    func largeSetFetches() async throws {
        let store = try await Self.threeMailboxStore()
        var ids = Set((0 ..< 2_500).map { "mbx_unused_\($0)" })
        ids.insert("mbx_b")
        let rows = try await store.conversations(accountID: Self.account, mailboxIDs: ids, folder: .inbox)
        #expect(rows.map(\.id) == ["thr_mbx_b"])
        #expect(try await store.unreadCount(accountID: Self.account, mailboxIDs: ids) == 1)
    }

    // MARK: - One thread, several mailboxes

    /// A conversation row per (thread, mailbox): `minute` orders them.
    private static func row(_ threadID: String, _ mailboxID: String, minute: Int, unread: Int = 1) -> ConversationSummary {
        let date = Date(timeIntervalSince1970: 10_000 + TimeInterval(minute * 60))
        let latest = MessageSummary(
            id: "m_\(threadID)_\(mailboxID)", threadID: threadID, mailboxID: mailboxID, direction: .inbound,
            folder: .inbox, fromAddress: "ada@example.net", to: [], subject: "s", snippet: "…",
            receivedAt: date, sentAt: nil, readAt: unread > 0 ? nil : date, starredAt: nil,
            hasAttachments: false, createdAt: date
        )
        return ConversationSummary(latest: latest, isStarred: false, messageCount: 1, unreadCount: unread)
    }

    /// `thr_shared` is listed under BOTH mbx_a and mbx_b. Fails on the old
    /// plain fetch (the thread twice in a multi-mailbox scope), if the older
    /// row wins, or if `limit`/`offset` count rows instead of threads (a page
    /// of 2 then holds one thread twice, and paging skips or repeats one).
    @Test("A multi-mailbox listing is deduped by thread, newest row first")
    func multiMailboxListingDedupes() async throws {
        let store = try MailStore.inMemory()
        for (thread, mailbox, minute) in [
            ("thr_shared", "mbx_a", 4), ("thr_shared", "mbx_b", 5), ("thr_a", "mbx_a", 3), ("thr_b", "mbx_b", 1),
        ] {
            _ = try await store.upsertConversations(
                [Self.row(thread, mailbox, minute: minute)], accountID: Self.account, mailboxID: mailbox, folder: .inbox
            )
        }
        for scope: Set<String>? in [nil, ["mbx_a", "mbx_b"]] {
            let all = try await store.conversations(accountID: Self.account, mailboxIDs: scope, folder: .inbox)
            #expect(all.map(\.id) == ["thr_shared", "thr_a", "thr_b"])
            #expect(all.first?.latest.mailboxID == "mbx_b", "the newest row of the thread")
            let first = try await store.conversations(accountID: Self.account, mailboxIDs: scope, folder: .inbox, limit: 2)
            let second = try await store.conversations(
                accountID: Self.account, mailboxIDs: scope, folder: .inbox, limit: 2, offset: 2
            )
            #expect(first.map(\.id) == ["thr_shared", "thr_a"])
            #expect(second.map(\.id) == ["thr_b"])
        }
        // One mailbox cannot hold a duplicate: its row, not the other's.
        let onlyA = try await store.conversations(accountID: Self.account, mailboxIDs: ["mbx_a"], folder: .inbox)
        #expect(onlyA.map(\.latest.id) == ["m_thr_shared_mbx_a", "m_thr_a_mbx_a"])
    }

    /// The one read every sidebar count is derived from: unread rows only,
    /// every listing scope, with the fields the folder rule needs. Fails if a
    /// read row is returned, or a field comes back defaulted (a
    /// `propertiesToFetch` that leaves one out).
    @Test("Unread keys: unread rows only, with their scope and folder")
    func unreadKeys() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertConversations(
            [Self.row("thr_u", "mbx_a", minute: 1), Self.row("thr_r", "mbx_a", minute: 2, unread: 0)],
            accountID: Self.account, mailboxID: "mbx_a", folder: .inbox
        )
        _ = try await store.upsertConversations(
            [Self.row("thr_u", "mbx_b", minute: 3)], accountID: Self.account, mailboxID: "mbx_b", folder: .starred
        )
        let keys = try await store.unreadConversationKeys(accountID: Self.account)
        #expect(Set(keys) == [
            UnreadConversationKey(
                threadID: "thr_u", mailboxKey: "mbx_a", listFolder: "inbox", folderRaw: "inbox",
                latestMessageID: "m_thr_u_mbx_a"
            ),
            UnreadConversationKey(
                threadID: "thr_u", mailboxKey: "mbx_b", listFolder: "starred", folderRaw: "inbox",
                latestMessageID: "m_thr_u_mbx_b"
            ),
        ])
    }

    /// The folder rule the counts share with `unreadCount`. Fails if a row a
    /// local archive moved out still counts in the Inbox, or not in Archived.
    @Test("An unread key counts where its row is presented")
    func unreadKeyFolderRule() {
        let moved = UnreadConversationKey(threadID: "t", mailboxKey: "m", listFolder: "inbox", folderRaw: "archived")
        #expect(!moved.counts(in: .inbox))
        #expect(!moved.counts(in: .archived), "listed under inbox: the archived listing has its own row")
        let archived = UnreadConversationKey(threadID: "t", mailboxKey: "m", listFolder: "archived", folderRaw: "archived")
        #expect(archived.counts(in: .archived))
        let inbox = UnreadConversationKey(threadID: "t", mailboxKey: "m", listFolder: "inbox", folderRaw: "catchall")
        #expect(inbox.counts(in: .inbox))
        #expect(!inbox.counts(in: .sent))
    }

    // MARK: - Label ∩ folder ∩ scope

    /// Fails if the label listing still spans every folder when a folder is
    /// given, or ignores the mailbox set — the redesign's "label combines with
    /// folder, narrows with scope".
    @Test("A label listing narrows to one folder and one mailbox set")
    func labelListingNarrows() async throws {
        let store = try MailStore.inMemory()
        let inboxA = SyncFixtures.conversation(threadID: "thr_inbox_a", latestID: "m1", mailboxID: "mbx_a")
        let inboxB = SyncFixtures.conversation(threadID: "thr_inbox_b", latestID: "m2", mailboxID: "mbx_b")
        let archivedA = SyncFixtures.conversation(threadID: "thr_arch_a", latestID: "m3", mailboxID: "mbx_a")
        let unlabelled = SyncFixtures.conversation(threadID: "thr_plain", latestID: "m4", mailboxID: "mbx_a")
        _ = try await store.upsertConversations([inboxA, unlabelled], accountID: Self.account, mailboxID: "mbx_a", folder: .inbox)
        _ = try await store.upsertConversations([inboxB], accountID: Self.account, mailboxID: "mbx_b", folder: .inbox)
        _ = try await store.upsertConversations([archivedA], accountID: Self.account, mailboxID: "mbx_a", folder: .archived)
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Client")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "m1", threadID: "thr_inbox_a"),
                LabelRowKey(messageID: "m2", threadID: "thr_inbox_b"),
                LabelRowKey(messageID: "m3", threadID: "thr_arch_a"),
            ],
            accountID: Self.account
        )

        let everywhere = try await store.conversations(withLabel: "lbl_1", accountID: Self.account)
        #expect(everywhere.count == 3, "no folder given still spans every folder")

        let inbox = try await store.conversations(withLabel: "lbl_1", accountID: Self.account, folder: .inbox)
        #expect(Set(inbox.map(\.id)) == ["thr_inbox_a", "thr_inbox_b"])

        let inboxOfA = try await store.conversations(
            withLabel: "lbl_1", accountID: Self.account, folder: .inbox, mailboxIDs: ["mbx_a"]
        )
        #expect(inboxOfA.map(\.id) == ["thr_inbox_a"])

        let archived = try await store.conversations(
            withLabel: "lbl_1", accountID: Self.account, folder: .archived, mailboxIDs: ["mbx_b"]
        )
        #expect(archived.isEmpty, "mbx_b has no archived labelled thread")

        let empty = try await store.conversations(
            withLabel: "lbl_1", accountID: Self.account, folder: .inbox, mailboxIDs: []
        )
        #expect(empty.isEmpty)
    }

    // MARK: - Drafts

    private static func draft(_ id: String, mailboxID: String?, minute: Int) -> Draft {
        Draft(
            id: id,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + minute * 60)),
            attachments: [],
            content: DraftInput(mailboxID: mailboxID, subject: id)
        )
    }

    /// The redesign's drafts rule: only the widest scope lists drafts tied to no
    /// mailbox, and a narrower scope lists only its own mailboxes' drafts. Fails
    /// if `mailboxKey == ""` rows leak into a mailbox scope, or drop out of the
    /// unassigned-inclusive one, or if the count disagrees with the list.
    @Test("Drafts filter by mailbox set, and only the widest scope includes mailbox-less ones")
    func draftsFollowTheScope() async throws {
        let store = try MailStore.inMemory()
        for draft in [
            Self.draft("d_a", mailboxID: "mbx_a", minute: 1),
            Self.draft("d_b", mailboxID: "mbx_b", minute: 2),
            Self.draft("d_none", mailboxID: nil, minute: 3),
        ] {
            _ = try await store.storeLocalDraft(draft, accountID: Self.account)
        }

        #expect(try await store.drafts(accountID: Self.account).map(\.id) == ["d_none", "d_b", "d_a"])
        #expect(try await store.draftCount(accountID: Self.account) == 3)

        let mailboxA = try await store.drafts(accountID: Self.account, mailboxIDs: ["mbx_a"], includingUnassigned: false)
        #expect(mailboxA.map(\.id) == ["d_a"])
        #expect(try await store.draftCount(accountID: Self.account, mailboxIDs: ["mbx_a"], includingUnassigned: false) == 1)

        let wideMinusB = try await store.drafts(accountID: Self.account, mailboxIDs: ["mbx_a"], includingUnassigned: true)
        #expect(wideMinusB.map(\.id) == ["d_none", "d_a"])

        let assignedOnly = try await store.drafts(accountID: Self.account, mailboxIDs: nil, includingUnassigned: false)
        #expect(Set(assignedOnly.map(\.id)) == ["d_a", "d_b"])

        #expect(try await store.drafts(accountID: Self.account, mailboxIDs: [], includingUnassigned: false).isEmpty)
        #expect(try await store.drafts(accountID: Self.account, mailboxIDs: [], includingUnassigned: true).map(\.id) == ["d_none"])
    }
}
