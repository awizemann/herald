import Foundation
import Testing
@testable import HeraldKit

/// Drafts as a cached surface: `GET /drafts` → full-list diff → `CachedDraft`.
///
/// The list half runs through the REAL `HQBaseAPIClient` against the URLProtocol
/// fake server, not a hand-written fake actor, so the JSON shape, the mapping and
/// the reconcile are all under test at once — a decoding regression here would
/// otherwise only show up against a live server.
@Suite("Draft sync")
struct DraftSyncTests {
    /// One draft's JSON in the shape `GET /drafts` returns.
    static func draftJSON(
        id: String,
        version: Int,
        updatedAt: String = "2026-08-14T10:00:00.000Z",
        subject: String = "Quote",
        to: [String] = ["ada@example.net"],
        text: String = "Here it is.",
        attachments: [String] = []
    ) -> String {
        let recipients = to.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "id": "\(id)",
          "version": \(version),
          "updatedAt": "\(updatedAt)",
          "attachments": [\(attachments.joined(separator: ","))],
          "mailboxId": "mbx_support",
          "replyToMessageId": null,
          "forwardOfMessageId": null,
          "from": "support@example.com",
          "to": [\(recipients)],
          "cc": [],
          "bcc": [],
          "subject": "\(subject)",
          "text": "\(text)",
          "html": "",
          \(Fixtures.draftSignatureAndLabelsJSON)
        }
        """
    }

    static func list(_ drafts: String...) -> FakeResponse {
        .json(200, "[\(drafts.joined(separator: ","))]")
    }

    static func client(_ server: FakeServer) -> HQBaseAPIClient {
        HQBaseAPIClient(origin: FakeServer.origin, tokens: FakeTokenProvider(), session: server.makeSession())
    }

    static let account = "acct_1"

    // MARK: - Reconcile

    /// Fails if the diff only ever ADDS: a draft the user deleted in the web app
    /// (or sent from another client) would linger in the Drafts folder forever,
    /// because drafts are absent from the `/changes` journal and nothing else
    /// would ever remove the row.
    @Test("A second listing without a draft deletes it from the cache")
    func reconcileDeletesWhatTheServerDropped() async throws {
        let server = FakeServer()
        server.route(
            "GET", "/api/v1/drafts",
            Self.list(Self.draftJSON(id: "dft_1", version: 1), Self.draftJSON(id: "dft_2", version: 1, subject: "Second")),
            Self.list(Self.draftJSON(id: "dft_1", version: 1))
        )
        let api = Self.client(server)
        let store = try MailStore.inMemory()

        let first = try await store.reconcileDrafts(try await api.listDrafts(), accountID: Self.account)
        #expect(first.inserted == ["dft_1", "dft_2"])
        #expect(try await store.drafts(accountID: Self.account).map(\.id).sorted() == ["dft_1", "dft_2"])

        let second = try await store.reconcileDrafts(try await api.listDrafts(), accountID: Self.account)
        #expect(second.deleted == ["dft_2"])
        #expect(second.inserted.isEmpty && second.updated.isEmpty)
        #expect(try await store.drafts(accountID: Self.account).map(\.id) == ["dft_1"])
        #expect(try await store.draftCount(accountID: Self.account) == 1)
    }

    /// Fails if the upsert blindly writes every field: an unchanged poll would
    /// report a change every 60 seconds and re-render the drafts list under the
    /// user's cursor for nothing.
    @Test("An identical listing changes nothing, a bumped version updates the row")
    func versionedUpdate() async throws {
        let server = FakeServer()
        server.route(
            "GET", "/api/v1/drafts",
            Self.list(Self.draftJSON(id: "dft_1", version: 1, subject: "Quote", text: "Draft one")),
            Self.list(Self.draftJSON(id: "dft_1", version: 1, subject: "Quote", text: "Draft one")),
            Self.list(
                Self.draftJSON(
                    id: "dft_1",
                    version: 2,
                    updatedAt: "2026-08-14T11:00:00.000Z",
                    subject: "Quote v2",
                    text: "Draft one, edited"
                )
            )
        )
        let api = Self.client(server)
        let store = try MailStore.inMemory()

        _ = try await store.reconcileDrafts(try await api.listDrafts(), accountID: Self.account)
        let unchanged = try await store.reconcileDrafts(try await api.listDrafts(), accountID: Self.account)
        #expect(unchanged.isEmpty, "an unchanged listing must not report a change")

        let changed = try await store.reconcileDrafts(try await api.listDrafts(), accountID: Self.account)
        #expect(changed.updated == ["dft_1"])

        let row = try #require(try await store.draft(id: "dft_1", accountID: Self.account))
        #expect(row.version == 2, "the version stamp is what PATCH must echo back")
        #expect(row.content.subject == "Quote v2")
        #expect(row.updatedAt == Fixtures.date("2026-08-14T11:00:00.000Z"))
    }

    /// Fails if the summary carries the whole body (or none of it): the row shows
    /// a preview, and handing the main actor a 100 KB draft body per row is the
    /// cost the DTO exists to avoid.
    @Test("The list DTO carries a collapsed snippet and the recipients, not the body")
    func summaryShape() async throws {
        let store = try MailStore.inMemory()
        let body = "Line one\n\n   Line two   \nLine three"
        try await store.reconcileDrafts(
            [Self.draft(id: "dft_1", version: 1, to: ["ada@example.net", "bo@example.net"], text: body)],
            accountID: Self.account
        )

        let summary = try #require(try await store.drafts(accountID: Self.account).first)
        #expect(summary.recipients == ["ada@example.net", "bo@example.net"])
        #expect(summary.snippet == "Line one Line two Line three")
        #expect(!summary.hasAttachments)
    }

    /// Fails if the newest-first sort is lost — the Drafts folder would show the
    /// draft the user is typing into somewhere in the middle of the list.
    @Test("Drafts list newest edit first")
    func newestFirst() async throws {
        let store = try MailStore.inMemory()
        try await store.reconcileDrafts(
            [
                Self.draft(id: "old", version: 1, updatedAt: Date(timeIntervalSince1970: 1_000)),
                Self.draft(id: "new", version: 1, updatedAt: Date(timeIntervalSince1970: 9_000)),
                Self.draft(id: "mid", version: 1, updatedAt: Date(timeIntervalSince1970: 5_000)),
            ],
            accountID: Self.account
        )
        #expect(try await store.drafts(accountID: Self.account).map(\.id) == ["new", "mid", "old"])
    }

    /// Fails if draft rows are not account-scoped: two HQBase instances reuse
    /// ids, and one account's poll would then tombstone the other's drafts.
    @Test("A reconcile for one account leaves the other account's drafts alone")
    func accountScoped() async throws {
        let store = try MailStore.inMemory()
        try await store.reconcileDrafts([Self.draft(id: "dft_1", version: 1)], accountID: "acct_1")
        try await store.reconcileDrafts([Self.draft(id: "dft_1", version: 7, subject: "Theirs")], accountID: "acct_2")

        // An empty listing for acct_1 must not touch acct_2's identically-named row.
        try await store.reconcileDrafts([], accountID: "acct_1")
        #expect(try await store.drafts(accountID: "acct_1").isEmpty)
        let theirs = try #require(try await store.draft(id: "dft_1", accountID: "acct_2"))
        #expect(theirs.version == 7)
    }

    // MARK: - Open-composer fence

    /// Fails if the poll is allowed to tombstone a draft a composer owns. The
    /// window creates its draft with `POST /drafts`; a `GET /drafts` issued
    /// BEFORE that returns cannot mention it, and an unfenced diff would delete
    /// the row the user is typing into — which the folder shows as a row that
    /// blinks out and back on every poll.
    @Test("A poll that predates a new draft does not delete the row the composer just wrote")
    func openDraftSurvivesAStaleListing() async throws {
        let store = try MailStore.inMemory()
        try await store.storeLocalDraft(Self.draft(id: "dft_new", version: 1), accountID: Self.account)

        let changes = try await store.reconcileDrafts([], accountID: Self.account)

        #expect(changes.isEmpty)
        #expect(try await store.drafts(accountID: Self.account).map(\.id) == ["dft_new"])

        // Once the window closes the fence goes and the poll owns the row again.
        await store.releaseOpenDraft(id: "dft_new", accountID: Self.account)
        #expect(try await store.reconcileDrafts([], accountID: Self.account).deleted == ["dft_new"])
    }

    /// Fails if a listing older than the composer's last save is written over the
    /// row: the Drafts folder would show the PREVIOUS text of the draft that is
    /// open in front of the user, until the next poll caught up.
    @Test("A listing older than the composer's last save does not overwrite the row")
    func openDraftIgnoresStaleVersions() async throws {
        let store = try MailStore.inMemory()
        try await store.storeLocalDraft(
            Self.draft(id: "dft_1", version: 5, subject: "What the user just typed"),
            accountID: Self.account
        )

        let stale = try await store.reconcileDrafts(
            [Self.draft(id: "dft_1", version: 4, subject: "Two saves ago")],
            accountID: Self.account
        )
        #expect(stale.isEmpty)
        #expect(try await store.draft(id: "dft_1", accountID: Self.account)?.content.subject == "What the user just typed")

        // A listing that is genuinely newer (another client saved it) still wins.
        let fresh = try await store.reconcileDrafts(
            [Self.draft(id: "dft_1", version: 6, subject: "Saved elsewhere")],
            accountID: Self.account
        )
        #expect(fresh.updated == ["dft_1"])
        #expect(try await store.draft(id: "dft_1", accountID: Self.account)?.content.subject == "Saved elsewhere")
    }

    /// Fails if a fence outlives its draft: an entry that is never cleared is a
    /// row the poll can never tombstone again for the life of the process.
    @Test("Deleting a draft, and purging an account, both drop the fence")
    func fenceIsReleased() async throws {
        let store = try MailStore.inMemory()
        try await store.storeLocalDraft(Self.draft(id: "dft_1", version: 1), accountID: Self.account)
        #expect(await store.isDraftOpen(id: "dft_1", accountID: Self.account))

        try await store.deleteDraft(id: "dft_1", accountID: Self.account)
        #expect(await store.isDraftOpen(id: "dft_1", accountID: Self.account) == false)

        try await store.storeLocalDraft(Self.draft(id: "dft_2", version: 1), accountID: Self.account)
        try await store.deleteAll(accountID: Self.account)
        #expect(await store.isDraftOpen(id: "dft_2", accountID: Self.account) == false)
        #expect(try await store.drafts(accountID: Self.account).isEmpty)
    }

    /// Fails if local saves are applied in arrival order. A composer reports its
    /// saves through a hop to the main actor, so an autosave and an attachment
    /// upload finishing together can arrive either way round — and the folder
    /// would then show a version of the draft the server has already moved past.
    @Test("An out-of-order local save is dropped, not written over the newer one")
    func outOfOrderLocalSaveIsDropped() async throws {
        let store = try MailStore.inMemory()
        try await store.storeLocalDraft(
            Self.draft(id: "dft_1", version: 9, subject: "Newest"),
            accountID: Self.account
        )

        let late = try await store.storeLocalDraft(
            Self.draft(id: "dft_1", version: 8, subject: "Older, arrived last"),
            accountID: Self.account
        )

        #expect(late.isEmpty)
        #expect(try await store.draft(id: "dft_1", accountID: Self.account)?.content.subject == "Newest")
    }

    // MARK: - Delete

    /// Fails if the local delete is not immediate: the row would sit in the
    /// folder until the next poll, which is up to a minute of a draft the user
    /// just deleted still being listed.
    @Test("Deleting a draft removes the row and reports it")
    func deleteRemovesTheRow() async throws {
        let store = try MailStore.inMemory()
        try await store.reconcileDrafts(
            [Self.draft(id: "dft_1", version: 1), Self.draft(id: "dft_2", version: 1)],
            accountID: Self.account
        )

        #expect(try await store.deleteDraft(id: "dft_1", accountID: Self.account).deleted == ["dft_1"])
        #expect(try await store.drafts(accountID: Self.account).map(\.id) == ["dft_2"])
        // Idempotent: deleting what is already gone is not an error and not a change.
        #expect(try await store.deleteDraft(id: "dft_1", accountID: Self.account).isEmpty)
    }

    // MARK: - Helpers

    static func draft(
        id: String,
        version: Int,
        updatedAt: Date = Date(timeIntervalSince1970: 3_000),
        to: [String] = ["ada@example.net"],
        subject: String = "Quote",
        text: String = "Here it is.",
        replyToMessageID: String? = nil,
        attachments: [DraftAttachment] = []
    ) -> Draft {
        Draft(
            id: id,
            version: version,
            updatedAt: updatedAt,
            attachments: attachments,
            content: DraftInput(
                mailboxID: "mbx_support",
                replyToMessageID: replyToMessageID,
                from: "support@example.com",
                to: to,
                subject: subject,
                text: text
            )
        )
    }
}
