import Foundation
import HeraldKit
import Testing
@testable import Herald

/// A send while an autosave PATCH is still on the wire.
///
/// `send()` cancels the debounce and waits for a first CREATE, but a later
/// PATCH already in flight is not awaited: it can land after the send consumed
/// the draft. Its answer belongs to a message that no longer exists, so it must
/// neither re-publish the draft to the Drafts folder (a ghost row after the
/// `.removed` the send reported) nor fail the composer that just sent.
@MainActor
@Suite struct ComposeSendSaveRaceTests {
    /// Fails if the late PATCH answer is adopted after the send: a `.saved`
    /// event follows `.removed`, or the status turns into a failure.
    @Test(.timeLimit(.minutes(1)))
    func aPatchLandingAfterTheSendIsIgnored() async throws {
        let api = FakeMailAPIClient()
        await api.enableCompose()
        var events: [String] = []
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: api),
            autosaveDelay: .zero,
            draftCache: { event in
                switch event {
                case .saved(let draft): events.append("saved:\(draft.id)")
                case .removed(let id): events.append("removed:\(id)")
                case .closed(let id): events.append("closed:\(id)")
                }
            }
        )
        model.toText = "you@example.com"
        model.subject = "Plans"
        await model.waitForAutosave()
        let draftID = try #require(model.draft.serverDraft?.id)

        await api.holdNextUpdate()
        model.bodyText = "Edited"
        try await wait("the PATCH to be in flight") { await api.parkedUpdateCount == 1 }

        #expect(await model.send())
        #expect(events.last == "removed:\(draftID)")

        let answeredBefore = await api.updatedDrafts.count
        await api.releaseUpdates()
        await model.waitForAutosave()
        try await wait("the held PATCH to be answered") { await api.updatedDrafts.count == answeredBefore + 1 }
        // Let the PATCH's continuation run back on the main actor.
        for _ in 0..<50 { await Task.yield() }

        #expect(events.last == "removed:\(draftID)", "a late save re-published the sent draft: \(events)")
        if case .failed(let reason) = model.status {
            Issue.record("the sent composer shows a failure: \(reason)")
        }
    }
}
