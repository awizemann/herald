import Foundation
import Testing
@testable import HeraldKit

/// Labels (upstream 1.3.4), as the v1 API actually delivers them.
///
/// The contract these pin down, verified live against a 1.3.4 instance:
/// `GET /api/v1/messages`, `/conversations` and `/changes` carry NO `labels`
/// field — the server gates that embed on `/api/v2` (`includeLabels` in
/// `worker/features/messages/routes.ts`). So membership on v1 can only be derived
/// by listing each label, and everything below is about doing that safely.
@Suite("Label sync")
struct LabelSyncTests {
    private static let account = SyncFixtures.account

    static func label(_ id: String, name: String, color: LabelColor = .blue) -> MailLabel {
        MailLabel(
            id: id,
            name: name,
            color: color,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func engine(
        api: FakeMailAPIClient,
        store: MailStore,
        labelPollInterval: Duration = .seconds(3_600),
        maxMessagePages: Int = SyncEngine.defaultMaxMessagePages
    ) -> SyncEngine {
        SyncEngine(
            api: api,
            store: store,
            maxMessagePages: maxMessagePages,
            // An hour: nothing in these tests can plausibly elapse the drafts one,
            // so the drafts poll never competes for the assertions.
            draftPollInterval: .seconds(3_600),
            labelPollInterval: labelPollInterval
        )
    }

    /// Fails if the sweep is put on the message cadence: it is one request PER
    /// LABEL, so a 15-second tick would multiply the poll cost by the workspace's
    /// label count for a surface that changes rarely.
    @Test("Labels are swept on the first pass and not again inside their interval")
    func labelsHaveTheirOwnInterval() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass cached the label") {
            (try? await store.labels(accountID: Self.account))?.count == 1
        }

        await engine.refreshNow()
        try await waitUntil("a second pass ran") {
            await api.callCount { if case .listMailboxes = $0 { return true } else { return false } } >= 2
        }
        #expect(
            await api.callCount { $0 == .listLabels } == 1,
            "a second pass inside the interval must not re-sweep every label"
        )

        // …but opening a label in the sidebar does force a fresh sweep.
        await engine.refreshLabelsNow()
        try await waitUntil("the forced sweep happened") {
            await api.callCount { $0 == .listLabels } == 2
        }
        await engine.stopAndWait()
    }

    /// Fails if membership is merged rather than replaced: the per-label listing
    /// is a COMPLETE statement about that label, so a message the server stopped
    /// returning has lost it and must leave the cache.
    @Test("A label's membership is replaced, so a removed message stops carrying it")
    func membershipIsReplaced() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            MessagePage(
                messages: [
                    SyncFixtures.message("msg_1", threadID: "thr_1"),
                    SyncFixtures.message("msg_2", threadID: "thr_2"),
                ],
                nextCursor: nil
            ),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep landed both assignments") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 2
        }

        // The second sweep sees only one of them.
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        await engine.refreshLabelsNow()
        try await waitUntil("the second sweep dropped the message that lost the label") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.count == 1
        }
        let index = try await store.labelIDsByThread(accountID: Self.account)
        #expect(index["thr_1"] == ["lbl_1"])
        #expect(index["thr_2"] == nil, "a thread the listing omitted must lose the label")
        await engine.stopAndWait()
    }

    /// Fails if a truncated page-walk is treated as a complete listing: that
    /// would erase every assignment the server had not got round to returning —
    /// the same trap the message tombstoning rule exists for.
    @Test("A page-capped membership walk leaves the cached assignments alone")
    func truncatedWalkDoesNotErase() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_1", threadID: "thr_1")], nextCursor: nil),
            forLabel: "lbl_1"
        )
        let store = try MailStore.inMemory()
        let first = engine(api: api, store: store)
        await first.start(accountID: Self.account)
        try await waitUntil("the first sweep landed the assignment") {
            (try? await store.labelIDsByThread(accountID: Self.account))?.isEmpty == false
        }
        await first.stopAndWait()

        // A server that now hands back an endless cursor chain, under a cap of 1.
        await api.setLabelMessages(
            MessagePage(messages: [SyncFixtures.message("msg_9", threadID: "thr_9")], nextCursor: "c1"),
            forLabel: "lbl_1"
        )
        let capped = engine(api: api, store: store, maxMessagePages: 1)
        await capped.start(accountID: Self.account)
        try await waitUntil("the capped sweep ran") {
            await api.callCount {
                if case .listMessagesByLabel = $0 { return true } else { return false }
            } >= 2
        }
        let index = try await store.labelIDsByThread(accountID: Self.account)
        #expect(
            index["thr_1"] == ["lbl_1"],
            "a walk that could not reach the end must not replace the label's membership"
        )
        #expect(index["thr_9"] == nil, "and must not half-apply the pages it did read")
        await capped.stopAndWait()
    }

    /// Fails if label changes ride in `.changed`: those ids are resolved against
    /// the MESSAGE cache by the view-model, and a label id resolves to nothing —
    /// which that code reads as "a brand-new mailbox" and reloads the sidebar for.
    @Test("A label change is emitted as .labelsChanged, and only when something changed")
    func labelsEmitTheirOwnEvent() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabels([Self.label("lbl_1", name: "Billing")])
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store)
        let recorder = LabelEventRecorder()
        let consumer = Task { await recorder.consume(engine.events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the first sweep reported the new label") {
            await recorder.labelsChanged == 1
        }

        // A second sweep of identical data must say nothing at all.
        await engine.refreshLabelsNow()
        try await waitUntil("the second sweep finished") { await recorder.finished >= 2 }
        #expect(
            await recorder.labelsChanged == 1,
            "an unchanged sweep must not invalidate the UI"
        )
        await engine.stopAndWait()
        consumer.cancel()
    }

    /// Fails if a 404 (a server older than labels) or a scope refusal is retried
    /// on every pass: it would be a guaranteed extra request per pass, forever,
    /// and — folded into the pass result — a healthy mailbox parked in backoff.
    @Test("A server without labels is probed once and then left alone")
    func missingLabelsRouteIsProbedOnce() async throws {
        let api = FakeMailAPIClient()
        await api.setMailboxes([SyncFixtures.mailbox("mbx_a")])
        await api.setLabelFailure(.notFound)
        let store = try MailStore.inMemory()
        let engine = engine(api: api, store: store, labelPollInterval: .zero)
        let recorder = LabelEventRecorder()
        let consumer = Task { await recorder.consume(engine.events) }

        await engine.start(accountID: Self.account)
        try await waitUntil("the first pass finished") { await recorder.finished >= 1 }
        // A second pass, asked for explicitly rather than waited out: the label
        // interval is zero here, so only the "probed once" rule can hold the
        // request count at one.
        await engine.refreshNow()
        try await waitUntil("two passes have finished") { await recorder.finished >= 2 }
        #expect(await api.callCount { $0 == .listLabels } == 1)
        #expect(await recorder.failures == 0, "a missing labels route is not a sync failure")
        await engine.stopAndWait()
        consumer.cancel()
    }
}

/// Counts the label-shaped events, and the pass boundary the assertions
/// synchronise on.
private actor LabelEventRecorder {
    private(set) var labelsChanged = 0
    private(set) var finished = 0
    private(set) var failures = 0

    func consume(_ events: AsyncStream<SyncEvent>) async {
        for await event in events {
            switch event {
            case .labelsChanged: labelsChanged += 1
            case .finished: finished += 1
            case .failed: failures += 1
            case .began, .changed, .draftsChanged: break
            }
        }
    }
}

/// The store half: what the cache does with labels once the sweep has written
/// them, and what an optimistic assignment does before the server answers.
@Suite("Label cache")
struct LabelCacheTests {
    private static let account = SyncFixtures.account

    @Test("A label listing crosses folders and shows one row per thread")
    func labelListingCrossesFolders() async throws {
        let store = try MailStore.inMemory()
        // The same thread listed under two scopes — which is normal: a thread in
        // the archive still has its inbox row until the next listing drops it.
        let inbox = SyncFixtures.conversation(threadID: "thr_1")
        try await store.upsertConversations([inbox], accountID: Self.account, mailboxID: "mbx_a", folder: .inbox)
        try await store.upsertConversations([inbox], accountID: Self.account, mailboxID: "mbx_a", folder: .archived)
        let trashed = SyncFixtures.conversation(threadID: "thr_2")
        try await store.upsertConversations([trashed], accountID: Self.account, mailboxID: "mbx_a", folder: .trash)

        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_1"),
                LabelRowKey(messageID: "msg_2", threadID: "thr_2"),
            ],
            accountID: Self.account
        )

        let rows = try await store.conversations(withLabel: "lbl_1", accountID: Self.account)
        #expect(rows.map(\.id).sorted() == ["thr_1", "thr_2"], "a label listing spans every folder")
        #expect(rows.count == 2, "a thread listed in two scopes must appear once, not twice")
    }

    /// Fails if a deleted label leaves its assignments behind: nothing else would
    /// ever remove them (the sweep only replaces the sets of labels it re-reads),
    /// so a thread would keep a chip for a label that no longer exists.
    @Test("A label the server stopped listing takes its assignments with it")
    func deletedLabelDropsItsAssignments() async throws {
        let store = try MailStore.inMemory()
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing"), LabelSyncTests.label("lbl_2", name: "Later")],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        #expect(try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_2"])

        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        #expect(try await store.labels(accountID: Self.account).map(\.id) == ["lbl_1"])
        #expect(
            try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == nil,
            "the deleted label's assignments must go with it"
        )
    }

    /// Fails if an unchanged sweep reports a change: the engine emits on the
    /// boolean, and a always-true one turns every sweep into a UI invalidation.
    @Test("Replacing labels with identical data reports no change")
    func unchangedReplaceReportsNothing() async throws {
        let store = try MailStore.inMemory()
        let labels = [LabelSyncTests.label("lbl_1", name: "Billing")]
        #expect(try await store.replaceLabels(labels, accountID: Self.account))
        #expect(try await store.replaceLabels(labels, accountID: Self.account) == false)
        let rows = [LabelRowKey(messageID: "msg_1", threadID: "thr_1")]
        #expect(try await store.replaceAssignments(labelID: "lbl_1", messages: rows, accountID: Self.account))
        #expect(
            try await store.replaceAssignments(labelID: "lbl_1", messages: rows, accountID: Self.account) == false
        )
    }

    /// Fails if a tombstoned message keeps its assignments: the row would go on
    /// appearing in the label's listing, and nothing would ever clean it up.
    @Test("Deleting a message drops its label assignments")
    func deletedMessageDropsAssignments() async throws {
        let store = try MailStore.inMemory()
        try await store.upsertMessages(
            [SyncFixtures.message("msg_1", threadID: "thr_1")], accountID: Self.account
        )
        try await store.replaceLabels([LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account)
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        try await store.deleteMessage(id: "msg_1", accountID: Self.account)
        #expect(try await store.labelIDsByThread(accountID: Self.account).isEmpty)
    }
}

/// The optimistic half: the cache moves first, and a rejection puts back exactly
/// what the optimistic write changed — no more.
@Suite("Label actions")
struct LabelActionTests {
    private static let account = SyncFixtures.account

    private func seededStore() async throws -> MailStore {
        let store = try MailStore.inMemory()
        try await store.upsertMessages(
            [
                SyncFixtures.message("msg_1", threadID: "thr_1"),
                SyncFixtures.message("msg_2", threadID: "thr_1"),
            ],
            accountID: Self.account
        )
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing")], accountID: Self.account
        )
        return store
    }

    @Test("Assigning a label to a conversation writes the cache before the server answers")
    func conversationAssignmentIsOptimistic() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabels([LabelSyncTests.label("lbl_1", name: "Billing")])
        let actions = MailActionService(api: api, store: store)

        // The request is HELD open, so the assertion below is about the
        // optimistic write and nothing else — awaiting the whole call first would
        // pass just as well if the cache were only written from the answer.
        await api.armGate()
        let write = Task {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        try await waitUntil("the optimistic write landed while the request is in flight") {
            (try? await store.labelIDsByThread(accountID: Self.account))?["thr_1"] == ["lbl_1"]
        }
        await api.openGate()
        try await write.value
        #expect(try await store.labelIDsByThread(accountID: Self.account)["thr_1"] == ["lbl_1"])
        // The conversation route takes a MESSAGE id — the same rule the triage
        // actions follow; a thread id resolves to no mailbox and 403s upstream.
        let writes = await api.calls.compactMap { call -> String? in
            if case .setConversationLabel(_, let messageID, _) = call { return messageID }
            return nil
        }
        #expect(writes == ["msg_1"] || writes == ["msg_2"])
    }

    /// Fails if a rejection is left for the next sweep to heal: that is up to two
    /// minutes of a chip the server never accepted.
    @Test("A rejected label change is reverted exactly")
    func rejectionReverts() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentFailure(.server(code: "http_403", message: "no"))
        let actions = MailActionService(api: api, store: store)

        await #expect(throws: MailAPIError.self) {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        #expect(
            try await store.labelIDsByThread(accountID: Self.account).isEmpty,
            "the optimistic chip must be gone once the server refused it"
        )
    }

    /// Fails if the revert takes away a label the action never granted: only the
    /// rows the optimistic write actually CHANGED belong to the undo.
    @Test("A revert leaves a label the action did not add")
    func revertKeepsPreexistingLabels() async throws {
        let store = try await seededStore()
        // msg_1 already carries the label; msg_2 does not.
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentFailure(.server(code: "http_403", message: "no"))
        let actions = MailActionService(api: api, store: store)

        await #expect(throws: MailAPIError.self) {
            try await actions.setLabel(
                "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: true
            )
        }
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_1"],
            "the revert must not remove the assignment that was already there"
        )
        #expect(try await store.labelIDs(messageID: "msg_2", accountID: Self.account).isEmpty)
    }

    /// Fails if a CONVERSATION answer's `labels` is written onto a message row.
    ///
    /// That field is the DISTINCT UNION across the thread, not any one message's
    /// set: applying it to the representative message hands that message labels
    /// only its siblings carry, and strips ones it holds alone. Only the label
    /// that was toggled is authoritative per message.
    @Test("A conversation answer's union is never written onto a single message")
    func conversationAnswerDoesNotOverwriteAMessageSet() async throws {
        let store = try await seededStore()
        try await store.replaceLabels(
            [LabelSyncTests.label("lbl_1", name: "Billing"), LabelSyncTests.label("lbl_2", name: "Later")],
            accountID: Self.account
        )
        // msg_1 carries both labels, msg_2 only the one about to be removed.
        try await store.replaceAssignments(
            labelID: "lbl_1",
            messages: [
                LabelRowKey(messageID: "msg_1", threadID: "thr_1"),
                LabelRowKey(messageID: "msg_2", threadID: "thr_1"),
            ],
            accountID: Self.account
        )
        try await store.replaceAssignments(
            labelID: "lbl_2",
            messages: [LabelRowKey(messageID: "msg_1", threadID: "thr_1")],
            accountID: Self.account
        )

        let api = FakeMailAPIClient()
        // What the real server answers for "remove lbl_1 from the thread": the
        // union of what the thread still carries — which is msg_1's label alone.
        await api.setLabelAssignmentResult(LabelAssignment(
            affected: 2,
            assigned: false,
            labelID: "lbl_1",
            threadID: "thr_1",
            labels: [LabelSyncTests.label("lbl_2", name: "Later")]
        ))
        let actions = MailActionService(api: api, store: store)
        try await actions.setLabel(
            "lbl_1", onConversation: "thr_1", accountID: Self.account, assigned: false
        )

        #expect(try await store.labelIDs(messageID: "msg_1", accountID: Self.account) == ["lbl_2"])
        #expect(
            try await store.labelIDs(messageID: "msg_2", accountID: Self.account).isEmpty,
            "the sibling's label must not be grafted onto the message the request was keyed by"
        )
    }

    /// The server's answer is the full set after the write, which is what lets a
    /// label assigned elsewhere show up without a second request.
    @Test("The server's answer replaces the message's label set")
    func serverAnswerIsAuthoritative() async throws {
        let store = try await seededStore()
        let api = FakeMailAPIClient()
        await api.setLabelAssignmentResult(LabelAssignment(
            affected: 1,
            assigned: true,
            labelID: "lbl_1",
            messageID: "msg_1",
            labels: [
                LabelSyncTests.label("lbl_1", name: "Billing"),
                LabelSyncTests.label("lbl_other", name: "Elsewhere"),
            ]
        ))
        let actions = MailActionService(api: api, store: store)

        try await actions.setLabel("lbl_1", onMessage: "msg_1", accountID: Self.account, assigned: true)
        #expect(
            try await store.labelIDs(messageID: "msg_1", accountID: Self.account).sorted()
                == ["lbl_1", "lbl_other"],
            "a label assigned elsewhere since the last sweep rides in on the answer"
        )
    }
}
