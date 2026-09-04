import Foundation
import SQLite3
import SwiftData
import Testing
@testable import HeraldKit
// `Testing` also exports an `Attachment`; this names ours for the whole file.
import struct HeraldKit.Attachment

/// The two data-integrity rules the cache depends on: a stored `Codable` blob can
/// never fail to decode, and tombstoning a message takes everything that named it.
@Suite("Cache integrity")
struct CacheIntegrityTests {
    private let account = SyncFixtures.account

    // MARK: - Blob decoding must be total

    /// The load-bearing one. SwiftData decodes a `Codable` column with `try!`, so
    /// a blob whose shape no longer matches the DTO is a PROCESS-FATAL trap inside
    /// `fetch`, not an error anything can catch — the exact thing that happens when
    /// a DTO gains a required field (as `Attachment.disposition` did).
    ///
    /// This writes a row, rewrites its blob column through SQLite with a payload in
    /// the OLD shape (one key, everything else missing), and fetches it back.
    /// Without the total `init(from:)` on `Attachment` the test process CRASHES
    /// here rather than failing.
    @Test("A blob in an obsolete shape degrades instead of trapping")
    func staleBlobShapeDoesNotTrap() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("MailCache.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Scoped so the container is released — and the store closed — before
        // SQLite touches the same file.
        do {
            let store = MailStore(modelContainer: try MailStoreContainer.make(url: url))
            _ = try await store.storeBody(
                messageID: "m1",
                accountID: account,
                textBody: "body",
                html: nil,
                attachments: [Self.attachment]
            )
        }

        // A payload written by a build whose `Attachment` had only an id.
        try Self.rewriteBlob(
            at: url,
            table: "ZCACHEDMESSAGEBODY",
            column: "ZATTACHMENTS",
            to: Data(#"[{"id":"att_1"}]"#.utf8)
        )

        let reopened = MailStore(modelContainer: try MailStoreContainer.make(url: url))
        let body = try await reopened.cachedBody(messageID: "m1", accountID: account)
        #expect(body?.textBody == "body", "The rest of the row must survive a degraded blob")
        #expect(body?.attachments.count == 1)
        // The one key that was present is honoured; the missing ones default.
        #expect(body?.attachments.first?.id == "att_1")
        #expect(body?.attachments.first?.disposition == .attachment)
        #expect(body?.attachments.first?.contentType == "application/octet-stream")
    }

    /// Fails if any blob DTO decodes a field it does not default: an empty object
    /// stands in for "every key this build expects was added after the row was
    /// written", which is the worst case of the same shape change.
    @Test("Every blob DTO decodes from an empty object")
    func blobDTOsDecodeFromNothing() throws {
        let empty = Data("{}".utf8)
        let decoder = JSONDecoder()

        let attachment = try decoder.decode(Attachment.self, from: empty)
        #expect(attachment.id.isEmpty)
        #expect(attachment.disposition == .attachment)

        let draftAttachment = try decoder.decode(DraftAttachment.self, from: empty)
        #expect(draftAttachment.sizeBytes == 0)

        let address = try decoder.decode(MailboxAddress.self, from: empty)
        #expect(address.sendEnabled == false)

        // An unknown `mode` must land on `.none` rather than throwing.
        let signature = try decoder.decode(
            SignatureSnapshot.self,
            from: Data(#"{"mode":"a-mode-from-the-future"}"#.utf8)
        )
        #expect(signature.mode == .none)
        #expect(signature == .empty)
    }

    /// Fails if a key is RETYPED rather than removed — the other half of a shape
    /// change, and the one a `decodeIfPresent`-only decoder would still throw on.
    @Test("A retyped blob field falls back instead of throwing")
    func retypedBlobFieldFallsBack() throws {
        let attachment = try JSONDecoder().decode(
            Attachment.self,
            from: Data(#"{"id":"att_1","sizeBytes":"not a number","filename":42}"#.utf8)
        )
        #expect(attachment.id == "att_1")
        #expect(attachment.sizeBytes == 0)
        #expect(attachment.filename.isEmpty)
    }

    /// The cost of hand-written `CodingKeys` is that a new property can be left out
    /// of them and silently stop persisting. A round trip is what catches that.
    @Test("Blob DTOs round-trip every field")
    func blobDTOsRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(Attachment.self, from: encoder.encode(Self.attachment)) == Self.attachment)

        let draftAttachment = DraftAttachment(
            id: "dat_1", filename: "notes.txt", contentType: "text/plain", sizeBytes: 12
        )
        #expect(
            try decoder.decode(DraftAttachment.self, from: encoder.encode(draftAttachment)) == draftAttachment
        )

        let address = MailboxAddress(
            id: "adr_1",
            mailboxID: "mbx_a",
            mailDomainID: "dom_1",
            address: "ada@example.com",
            displayName: "Ada",
            receiveEnabled: true,
            sendEnabled: true,
            isPrimary: true
        )
        #expect(try decoder.decode(MailboxAddress.self, from: encoder.encode(address)) == address)

        let signature = SignatureSnapshot(
            mode: .selected, id: "sig_1", name: "Work", html: "<p>Ada</p>", text: "Ada"
        )
        #expect(try decoder.decode(SignatureSnapshot.self, from: encoder.encode(signature)) == signature)
    }

    // MARK: - Tombstoning cascade

    /// Fails if `deleteMissingMessages` drops the message row alone. Every orphan
    /// it used to leave is durable: the assignment keeps the dead message in its
    /// label's listing forever (the sweep only REPLACES the set of a label it
    /// re-reads), the sidecar is a body nothing can reach, and the fence blocks the
    /// journal from ever writing that id again.
    @Test("Tombstoning cascades to bodies, labels and the pending fence")
    func tombstoningCascades() async throws {
        let store = try MailStore.inMemory()
        _ = try await store.upsertMessages(
            [
                SyncFixtures.message("m1", mailboxID: "mbx_a", folder: .inbox),
                SyncFixtures.message("m2", threadID: "thr_2", mailboxID: "mbx_a", folder: .inbox),
                // A SECOND doomed row: the cascade batch-deletes inside the loop
                // over the fetched rows, so one tombstone would not prove the
                // iteration survives its own deletes.
                SyncFixtures.message("m3", threadID: "thr_3", mailboxID: "mbx_a", folder: .inbox),
            ],
            accountID: account
        )
        for id in ["m1", "m2", "m3"] {
            _ = try await store.storeBody(
                messageID: id, accountID: account, textBody: "body", html: nil, attachments: [Self.attachment]
            )
        }
        _ = try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "m1", threadID: "thr_1"),
                LabelRowKey(messageID: "m2", threadID: "thr_2"),
                LabelRowKey(messageID: "m3", threadID: "thr_3"),
            ],
            accountID: account
        )
        // A local star on m2 leaves a pending fence behind for the delete to clear.
        _ = try await store.applyLocalAction(.star, messageID: "m2", accountID: account)
        #expect(await store.hasPendingMutation(messageID: "m2", accountID: account))

        let changes = try await store.deleteMissingMessages(
            accountID: account, mailboxID: "mbx_a", folder: .inbox, keeping: ["m1"]
        )

        #expect(changes.deleted == ["m2", "m3"])
        #expect(try await store.cachedBody(messageID: "m3", accountID: account) == nil)
        #expect(try await store.labelIDs(messageID: "m3", accountID: account).isEmpty)
        #expect(try await store.cachedBody(messageID: "m2", accountID: account) == nil, "Orphaned body sidecar")
        #expect(try await store.labelIDs(messageID: "m2", accountID: account).isEmpty, "Orphaned label assignment")
        #expect(
            await store.hasPendingMutation(messageID: "m2", accountID: account) == false,
            "A fence on a deleted row blocks the journal forever"
        )

        // The surviving message keeps everything: the cascade is per-row, not a sweep.
        #expect(try await store.message(id: "m1", accountID: account) != nil)
        #expect(try await store.cachedBody(messageID: "m1", accountID: account) != nil)
        #expect(try await store.labelIDs(messageID: "m1", accountID: account) == ["lbl_1"])
    }

    // MARK: - Fixtures

    private static let attachment = Attachment(
        id: "att_1",
        messageID: "m1",
        filename: "invoice.pdf",
        contentType: "application/pdf",
        sizeBytes: 2_048,
        contentID: nil,
        disposition: .attachment,
        createdAt: Date(timeIntervalSince1970: 1_000)
    )

    /// Overwrites a blob column in the closed store file — the only way to stage a
    /// row written by a build whose DTO had a different shape.
    private static func rewriteBlob(at url: URL, table: String, column: String, to data: Data) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // The store's own connection may not be torn down yet — SwiftData offers
        // no explicit close — so wait for its lock rather than racing it.
        sqlite3_busy_timeout(db, 5_000)
        var statement: OpaquePointer?
        var prepared = sqlite3_prepare_v2(db, "UPDATE \(table) SET \(column) = ?", -1, &statement, nil)
        // A schema read blocked by that lock comes back LOCKED/BUSY, and
        // `sqlite3_busy_timeout` does not cover schema loading; retry briefly.
        var attempts = 0
        while prepared != SQLITE_OK, attempts < 50 {
            usleep(100_000)
            attempts += 1
            prepared = sqlite3_prepare_v2(db, "UPDATE \(table) SET \(column) = ?", -1, &statement, nil)
        }
        try #require(prepared == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        defer { sqlite3_finalize(statement) }
        let stepped = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(raw.count), nil)
            return sqlite3_step(statement)
        }
        try #require(stepped == SQLITE_DONE)
    }
}
