import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Two-tier search: the widened LOCAL index, the SERVER tier that backs it up,
/// and the highlighting that shows why a row is on screen.
@MainActor
@Suite("Search")
struct SearchTests {
    /// A view-model over an in-memory store, seeded with one inbox thread per
    /// caller-supplied message.
    private struct Harness {
        let store: MailStore
        let api: FakeMailAPIClient
        let model: MailViewModel

        static func make(_ messages: [MessageSummary]) async throws -> Harness {
            let store = try MailStore.inMemory()
            let api = FakeMailAPIClient()
            let (stream, _) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .unbounded)
            let model = MailViewModel(
                accountID: "acct",
                accountLabel: "Test",
                api: api,
                store: store,
                actions: MailActionService(api: api, store: store),
                events: stream,
                markReadDelay: .seconds(3600)
            )
            try await store.upsertMessages(messages, accountID: "acct")
            try await store.upsertConversations(
                messages.map { MailFixtures.conversation($0) },
                accountID: "acct",
                mailboxID: "mbA",
                folder: .inbox
            )
            model.selection = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .inbox)
            await model.reloadConversations()
            return Harness(store: store, api: api, model: model)
        }

        /// Waits for whatever server pass is in flight, if any.
        func settle() async {
            await model.serverSearchTask?.value
        }

        /// Waits for the body index to be loaded and settled.
        ///
        /// Awaited TWICE on purpose: a pass that finishes with a coalesced
        /// request pending starts exactly one successor (see
        /// `refreshBodySearchIndex`), and the second await lands on that one.
        /// Asserting on the index without this is asserting on a race — it is
        /// what made this suite fail roughly one full-suite run in two.
        func settleBodyIndex() async {
            await model.bodyIndexTask?.value
            await model.bodyIndexTask?.value
        }
    }

    private static func remoteRow(_ id: String, subject: String) -> ConversationSummary {
        MailFixtures.conversation(
            MailFixtures.message(id: "m-\(id)", threadID: id, mailboxID: "mbA", subject: subject)
        )
    }

    // MARK: - Local index

    /// Fails if the index is still subject+from+snippet only: searching for a
    /// RECIPIENT ("who did I send this to") is half of what search is for, and
    /// `to` is already on the row DTO.
    @Test("The local index matches recipients, not just sender and subject")
    func localIndexCoversRecipients() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha", to: ["dana@example.com"]),
            MailFixtures.message(id: "m2", threadID: "t2", subject: "Beta", to: ["erik@example.com"]),
        ])

        harness.model.searchQuery = "dana@"
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])
    }

    /// Fails if the body sidecar is left out of the index: a mail whose only
    /// occurrence of the needle is in the body the user already read is exactly
    /// the mail they are trying to find again.
    ///
    /// ALSO fails if a re-index over an unchanged row set is dropped instead of
    /// coalesced. The body is cached here AFTER the harness's first index pass
    /// has been dispatched — exactly what the reading pane does — and the reload
    /// that follows asks for the same ids. Whenever that first pass is still in
    /// flight, dedupe-and-drop leaves its stale, body-less answer as the index
    /// and "platypus" matches nothing. That is what made this suite fail about
    /// one full-suite run in two; the coalesced re-run is what fixes it.
    @Test("A cached body is searchable, an uncached one is not")
    func localIndexCoversCachedBodies() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha"),
            MailFixtures.message(id: "m2", threadID: "t2", subject: "Beta"),
        ])
        try await harness.store.storeBody(
            messageID: "m1", accountID: "acct", textBody: "the PLATYPUS clause", html: nil
        )
        // The index is loaded off the store, so it lands on the reload.
        await harness.model.reloadConversations()
        await harness.settleBodyIndex()

        harness.model.searchQuery = "platypus"
        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])

        // …and a body nobody has read is not silently matched.
        harness.model.searchQuery = "clause of beta"
        #expect(harness.model.presentedConversations.isEmpty)
    }

    // MARK: - Server tier

    /// Fails if the server call drops the scope, sends the untrimmed field text,
    /// or stops paging — each produces results the list quietly mis-scopes.
    @Test("Submitting pages the server search through the cursor, in scope")
    func serverSearchPagesInScope() async throws {
        // Three local hits, so the sparse-result auto-search stays out of the way
        // and this asserts the SUBMIT path exactly once.
        let harness = try await Harness.make(
            (1...3).map {
                MailFixtures.message(id: "m\($0)", threadID: "t\($0)", subject: "Zulu local \($0)")
            }
        )
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t9", subject: "Zulu one")],
                nextCursor: "c2",
                totalCount: nil
            )
        )
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t8", subject: "Zulu two")],
                nextCursor: nil,
                totalCount: nil
            ),
            forCursor: "c2"
        )

        harness.model.searchQuery = "  zulu  "
        #expect(harness.model.serverSearchCount == 0, "A well-stocked local result still hit the network")
        harness.model.submitSearch()
        await harness.settle()

        let searches = await harness.api.searches()
        #expect(searches.map(\.search) == ["zulu", "zulu"], "The needle was not trimmed, or paging stopped")
        #expect(searches.allSatisfy { $0.folder == .inbox && $0.mailboxID == "mbA" })
        #expect(searches.map(\.cursor) == [nil, "c2"])
        #expect(harness.model.serverSearchState == .completed(2))
        // Union: three local matches plus the two the server added.
        #expect(Set(harness.model.presentedConversations.map(\.id)) == ["t1", "t2", "t3", "t8", "t9"])
    }

    /// Fails if the union double-counts: a thread that is BOTH cached and
    /// returned by the server must appear once, as the local (optimistically
    /// up-to-date) copy.
    @Test("A thread in both tiers is presented once, from the cache")
    func unionDedupesAgainstTheCache() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Zulu local")
        ])
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [
                    Self.remoteRow("t1", subject: "Zulu stale"),
                    Self.remoteRow("t9", subject: "Zulu remote"),
                ],
                nextCursor: nil,
                totalCount: nil
            )
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()

        let rows = harness.model.presentedConversations
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.id == "t1" })?.latest.subject == "Zulu local")
    }

    /// Fails if a sparse local result does NOT reach for the server — the whole
    /// point of the second tier is the answer being older than the cache — or if
    /// a query too short to be an answer hits the network anyway.
    @Test("A sparse local result searches the server; a one-character one does not")
    func sparseResultAutoSearchesButShortNeedleDoesNot() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])

        harness.model.searchQuery = "z"
        await harness.settle()
        #expect(harness.model.serverSearchCount == 0, "A one-character LIKE %z% scan was sent")

        harness.model.searchQuery = "zulu"
        await harness.settle()
        #expect(harness.model.serverSearchCount == 1)
    }

    /// Fails if a query change lets the older pass finish into the list: the
    /// classic stale-result race, where the rows on screen answer the needle the
    /// user just backspaced away from.
    @Test("A superseded server search cannot land its results")
    func queryChangeCancelsInFlightSearch() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t9", subject: "Zulu remote")],
                nextCursor: nil,
                totalCount: nil
            )
        )
        await harness.api.closeConversationGate()

        harness.model.searchQuery = "zulu"
        let inFlight = harness.model.serverSearchTask
        #expect(inFlight != nil)
        await harness.api.waitForPendingSearch()

        // The user keeps typing — down to a needle too short to re-search, so
        // nothing else can be confused for the cancelled pass's effect.
        harness.model.searchQuery = "z"
        await harness.api.openConversationGate()
        await inFlight?.value

        #expect(harness.model.presentedConversations.isEmpty, "A stale server row landed under a new query")
        #expect(harness.model.serverSearchState == .idle)
    }

    /// Fails if an offline server search either clears the local results or
    /// reports a raw URLError string: the list is still useful, and "offline" is
    /// the whole explanation.
    @Test("Offline leaves local results in place and says so")
    func offlineFallsBackToLocalOnly() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Zulu local")
        ])
        await harness.api.setConversationError(
            .transport(MailAPIError.TransportFailure(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            ))
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()

        #expect(harness.model.presentedConversations.map(\.id) == ["t1"])
        #expect(harness.model.serverSearchState == .failed("Offline — showing local results only"))
        #expect(harness.model.serverSearchDescription == "Offline — showing local results only")
    }

    /// Fails if a folder switch leaves the previous scope's server rows on
    /// screen — they were matched against a folder the user has left.
    @Test("Changing folder drops the server results")
    func scopeChangeDropsServerResults() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t9", subject: "Zulu remote")],
                nextCursor: nil,
                totalCount: nil
            )
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()
        #expect(harness.model.presentedConversations.map(\.id) == ["t9"])

        harness.model.selection = MailViewModel.FolderSelection(mailboxID: "mbA", folder: .archived)
        #expect(harness.model.presentedConversations.isEmpty)
        #expect(harness.model.serverSearchState == .idle)
    }

    /// Fails on the dead end the union creates if selection is still resolved
    /// against the cache alone: a row only the SERVER found would select into a
    /// blank reading pane with no subject and no messages — which is precisely
    /// the row the second tier exists to surface.
    @Test("A server-only row is selectable and opens its messages")
    func serverOnlyRowResolvesOnSelection() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])
        let remoteLatest = MailFixtures.message(
            id: "m9", threadID: "t9", mailboxID: "mbA", subject: "Zulu remote"
        )
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [MailFixtures.conversation(remoteLatest, messageCount: 2)],
                nextCursor: nil,
                totalCount: nil
            )
        )
        let older = MailFixtures.message(
            id: "m8", threadID: "t9", mailboxID: "mbA", subject: "Zulu remote",
            date: MailFixtures.epoch.addingTimeInterval(-60)
        )
        await harness.api.setThread(
            [MailFixtures.detail(remoteLatest), MailFixtures.detail(older)], forMessage: "m9"
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()

        harness.model.selectedThreadID = "t9"
        #expect(harness.model.selectedConversation?.latest.subject == "Zulu remote")
        await harness.model.loadThread("t9")
        // Newest first, like every other thread list in the app.
        #expect(harness.model.threadMessages.map(\.id) == ["m9", "m8"])
    }

    /// Fails if a reload deselects a server-only row: `reloadConversations` runs
    /// on every sync tick, so resolving the selection against the cache alone
    /// tore the reading pane down under the user mid-read.
    @Test("A sync reload keeps a server-only row selected")
    func reloadKeepsServerOnlySelection() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t9", subject: "Zulu remote")],
                nextCursor: nil,
                totalCount: nil
            )
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()
        harness.model.selectedThreadID = "t9"

        await harness.model.reloadConversations()
        #expect(harness.model.selectedThreadID == "t9")
    }

    /// Fails if an archived server-only row is re-unioned from its stale
    /// snapshot: nothing re-derives a DTO that has no cache row behind it, so the
    /// row springs back still claiming the folder it just left.
    @Test("Archiving a server-only row does not resurrect it")
    func archivingDropsTheServerSnapshot() async throws {
        let harness = try await Harness.make([
            MailFixtures.message(id: "m1", threadID: "t1", subject: "Alpha")
        ])
        await harness.api.setConversationPage(
            ConversationPage(
                conversations: [Self.remoteRow("t9", subject: "Zulu remote")],
                nextCursor: nil,
                totalCount: nil
            )
        )

        harness.model.searchQuery = "zulu"
        harness.model.submitSearch()
        await harness.settle()
        #expect(harness.model.presentedConversations.map(\.id) == ["t9"])

        await harness.model.perform(.archive, onThread: "t9")
        #expect(harness.model.presentedConversations.isEmpty, "The archived server row came back")
    }

    // MARK: - Highlighting

    /// Fails on the three ways match-finding breaks: an empty needle looping or
    /// marking everything, a case-different occurrence going unmarked, and a
    /// second occurrence being dropped.
    @Test("Matches are case-insensitive, repeated and never empty")
    func highlightRangesAreExact() {
        let text = "Invoice for the invoice team"
        let ranges = SearchHighlighter.ranges(of: "InVoIcE", in: text)
        #expect(ranges.count == 2)
        #expect(ranges.map { String(text[$0]) } == ["Invoice", "invoice"])

        #expect(SearchHighlighter.ranges(of: "", in: text).isEmpty)
        #expect(SearchHighlighter.ranges(of: "   ", in: text).isEmpty)
        #expect(SearchHighlighter.ranges(of: "absent", in: text).isEmpty)
    }

    /// Fails if the highlighted string is not the original string: dropping or
    /// duplicating a character between the marked runs would silently corrupt
    /// every row's subject the moment the user searches.
    @Test("Highlighting preserves the text and marks exactly the matches")
    func highlightPreservesText() {
        let text = "Q3 invoice — invoice copy"
        let attributed = SearchHighlighter.highlight(text, matching: "invoice")
        #expect(String(attributed.characters) == text)

        let marked = attributed.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        #expect(marked == ["invoice", "invoice"])

        // No search, no attributes — the common case must stay plain.
        let plain = SearchHighlighter.highlight(text, matching: "")
        #expect(plain.runs.count == 1)
    }
}
