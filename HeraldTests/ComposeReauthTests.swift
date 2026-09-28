import Foundation
import HeraldKit
import Testing
@testable import Herald

/// P4 of the 2026-09-26 session-recovery plan: a compose window is never a dead
/// end when its account's session dies, and never loses a word across the
/// re-auth that repairs it.
///
/// The incident: a draft autosave 401'd, then Send 401'd, and the error bar said
/// "Your session has expired. Sign in again." with nothing to click. The draft
/// existed only in the window. The re-auth then CLOSED the composer's session
/// while the window kept its view-model — bound to the superseded graph's
/// outbox — so a scene rebuild would have shown "no longer available" over the
/// half-written message, and the send that finally worked did so only because
/// the old client's provider happened to re-read the new Keychain grant.
@MainActor
@Suite(.scratchDefaults) struct ComposeReauthTests {
    private static let a = Account(origin: URL(string: "https://a.example.com")!, clientID: "cid", scopes: [])
    private static let b = Account(origin: URL(string: "https://b.example.com")!, clientID: "cid", scopes: [])

    private static func environment(accounts: [Account] = [a, b]) -> AppEnvironment {
        let defaults = ScratchDefaults.make()
        return AppEnvironment(
            auth: AuthCoordinator(store: InMemoryAccountStore(accounts: accounts)),
            defaults: defaults,
            // In the background: nothing here may start an automatic sign-in.
            isApplicationActive: { false }
        )
    }

    /// A fake server whose draft and send routes work — or, with `dead`, all
    /// answer 401 like a server whose bound web session is gone.
    private static func composeAPI(dead: Bool = false) async -> FakeMailAPIClient {
        let api = FakeMailAPIClient()
        await api.enableCompose()
        if dead { await api.setComposeError(.unauthorized) }
        return api
    }

    private static func deadSession() -> OutboxError { .api(.unauthorized) }

    // MARK: - The view-model's classification

    /// Fails if a dead-session send leaves the bar without its Sign In (the
    /// incident), or if an ordinary failure — a timeout, a 404 — grows one:
    /// signing in again would fix nothing there, and Retry-by-Send is right.
    @Test func aDeadSessionSendOffersSignInAndOtherFailuresDoNot() async {
        let outbox = FakeOutbox()
        await outbox.setSendError(Self.deadSession())
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
        model.toText = "friend@example.com"
        model.bodyText = "Hello"

        #expect(await model.send() == false)
        #expect(model.requiresSignIn)
        #expect(model.signInAffordance == .available)
        #expect(model.status.message == OutboxError.api(.unauthorized).localizedDescription)

        for failure: OutboxError in [.api(.transport(.init(URLError(.timedOut)))), .api(.notFound)] {
            await outbox.setSendError(failure)
            #expect(await model.send() == false)
            #expect(model.requiresSignIn == false, "\(failure) is not a dead session")
            #expect(model.signInAffordance == .none)
            #expect(model.status.message != nil, "a non-auth failure keeps today's bar")
        }
    }

    /// The button turns into progress while ANY attempt for the account runs —
    /// the banner's, the sidebar's, Herald's own — because a click would only be
    /// refused by the one-window policy. Fails if it offers a second window, or
    /// shows up with no dead session behind it.
    @Test func theSignInAffordanceFollowsTheAttemptState() {
        typealias Model = ComposeViewModel
        #expect(Model.signInAffordance(requiresSignIn: true, isSigningIn: false) == .available)
        #expect(Model.signInAffordance(requiresSignIn: true, isSigningIn: true) == .inProgress)
        #expect(Model.signInAffordance(requiresSignIn: false, isSigningIn: true) == .none)
        #expect(Model.signInAffordance(requiresSignIn: false, isSigningIn: false) == .none)
    }

    /// The autosave half of the incident. Fails if an autosave 401 only logs
    /// (no way back in), if typing on clears the bar and queues another doomed
    /// autosave per debounce (a 401 and a VoiceOver announcement per pause in
    /// typing), or if autosave does not RESUME — through the NEW outbox, with
    /// everything typed meanwhile — once the account is signed in again.
    @Test func aDeadSessionPausesAutosaveAndSigningInResumesIt() async {
        let dead = FakeOutbox()
        await dead.setSaveError(Self.deadSession())
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: dead,
            autosaveDelay: .zero
        )
        model.subject = "Plans"
        await model.waitForAutosave()
        #expect(model.requiresSignIn, "an autosave 401 must surface the same Sign In as a send")
        let announced = model.announcementCount

        model.bodyText = "Typed while the session was dead"
        await model.waitForAutosave()
        #expect(await dead.saveCount == 1, "typing queued another autosave against the dead session")
        #expect(model.requiresSignIn, "typing cleared the Sign In")
        #expect(model.announcementCount == announced, "the failure was re-announced while typing")

        let live = FakeOutbox()
        model.accountSignedIn(outbox: live)
        #expect(model.requiresSignIn == false)
        #expect(model.status == .idle)
        #expect(model.announcement == "Signed in again. Press Send to send your message.")
        await model.waitForAutosave()
        #expect(await live.saveCount == 1, "autosave did not resume after signing in")
        #expect(await live.lastSaved?.body == "Typed while the session was dead")
        #expect(await dead.saveCount == 1, "the superseded outbox was used after the rebind")
    }

    /// Signing in NEVER sends by itself — Alan's decision: the user presses Send
    /// again. Fails if the rebind resends, or rotates or re-mints the send key
    /// (a retry after a 401, which the server never accepted, must reuse it).
    @Test func signingInSendsNothingAndKeepsTheSendKey() async {
        let dead = FakeOutbox()
        await dead.setSendError(Self.deadSession())
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: dead,
            autosaveDelay: .seconds(3600)
        )
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        let key = model.draft.sendAttemptKey
        #expect(await model.send() == false)

        let live = FakeOutbox()
        model.accountSignedIn(outbox: live)
        #expect(await live.sendCount == 0, "signing in sent the message by itself")
        #expect(model.isClosed == false)
        #expect(model.draft.sendAttemptKey == key)

        #expect(await model.send())
        #expect(await live.lastSent?.sendAttemptKey == key, "the retry changed identity")
        #expect(await dead.sendCount == 1)
    }

    /// A send already in flight on the OLD outbox when the re-auth lands comes
    /// back 401 — about the grant that was just replaced. Fails if that stale
    /// answer re-raises Sign In over a healthy account (the user would be sent
    /// through consent a second time for nothing); the failure itself is still
    /// shown, and Send from the same window goes through the new outbox.
    @Test func aStaleDeadSessionAnswerAfterSigningInOffersNoSecondSignIn() async throws {
        let dead = FakeOutbox()
        await dead.setSendError(Self.deadSession())
        await dead.holdSends()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: dead,
            autosaveDelay: .seconds(3600)
        )
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        let inFlight = Task { await model.send() }
        try await wait("the send to reach the old outbox") { await dead.parkedSendCount == 1 }

        let live = FakeOutbox()
        model.accountSignedIn(outbox: live)
        await dead.releaseSends()
        #expect(await inFlight.value == false)

        #expect(model.status.message != nil)
        #expect(model.requiresSignIn == false, "a stale 401 asked for a second sign-in")
        #expect(await model.send())
        #expect(await live.sendCount == 1)
    }

    // MARK: - One server draft across a rebind (D4)

    /// A first autosave's `POST /drafts` is still in flight on the OLD graph's
    /// outbox when the re-auth rebinds the composer, and the user keeps typing.
    /// `OutboxService` only deduplicates creates per instance, so the edit's
    /// autosave through the NEW outbox used to create a second server draft
    /// (the first orphaned in the Drafts folder). Fails unless exactly one
    /// create happens and the edit lands as an update of that draft.
    @Test(.timeLimit(.minutes(1)))
    func aCreateInFlightAcrossARebindIsNotDuplicated() async throws {
        let oldAPI = await Self.composeAPI()
        await oldAPI.holdCreates()
        let newAPI = await Self.composeAPI()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: oldAPI),
            autosaveDelay: .zero
        )
        model.subject = "Plans"
        try await wait("the first create to be in flight on the old outbox") { await oldAPI.parkedCreateCount == 1 }

        model.accountSignedIn(outbox: OutboxService(api: newAPI))
        model.bodyText = "Typed after signing in"
        // Give the new autosave every chance to go out while the create is held.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await newAPI.createdDrafts.isEmpty, "a second create went out while the first was in flight")

        await oldAPI.releaseCreates()
        try await wait("the edit to be saved") { await newAPI.updatedDrafts.count == 1 }
        await model.waitForAutosave()

        let creates = await oldAPI.createdDrafts.count + newAPI.createdDrafts.count
        #expect(creates == 1, "one composer created \(creates) server drafts")
        #expect(await newAPI.updatedDrafts.first?.text == "Typed after signing in")
        #expect(model.draft.serverDraft?.id == "draft-1")
    }

    /// The attachment path: dropping a file onto a composer with no server
    /// draft creates one first. Held on the old outbox across the rebind, then
    /// an edit: still exactly one create. Fails if uploads are not serialized
    /// with saves.
    @Test(.timeLimit(.minutes(1)))
    func anUploadsCreateInFlightAcrossARebindIsNotDuplicated() async throws {
        let oldAPI = await Self.composeAPI()
        await oldAPI.holdCreates()
        let newAPI = await Self.composeAPI()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: oldAPI),
            autosaveDelay: .zero
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("d4-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let upload = Task { await model.attach(file) }
        try await wait("the upload's create to be in flight on the old outbox") { await oldAPI.parkedCreateCount == 1 }

        model.accountSignedIn(outbox: OutboxService(api: newAPI))
        model.subject = "Typed after signing in"
        try await Task.sleep(for: .milliseconds(50))
        #expect(await newAPI.createdDrafts.isEmpty, "a second create went out while the upload's was in flight")

        await oldAPI.releaseCreates()
        await upload.value
        try await wait("the edit to be saved") { await newAPI.updatedDrafts.count == 1 }
        await model.waitForAutosave()

        let creates = await oldAPI.createdDrafts.count + newAPI.createdDrafts.count
        #expect(creates == 1, "one composer created \(creates) server drafts")
        // The create went out on the old outbox; the upload itself, after it,
        // through the composer's CURRENT one.
        #expect(await oldAPI.uploadedAttachments.isEmpty)
        #expect(await newAPI.uploadedAttachments.count == 1)
        #expect(model.draft.serverDraft?.id == "draft-1")
    }

    /// Delete Draft while the first save is still creating the server draft:
    /// the delete must wait for the create and remove what it made. Fails if
    /// the delete runs against "no server draft yet" and the create lands
    /// after it, leaving the thrown-away draft on the server.
    @Test(.timeLimit(.minutes(1)))
    func discardDuringAnInFlightCreateDeletesTheCreatedDraft() async throws {
        let api = await Self.composeAPI()
        await api.holdCreates()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: api),
            autosaveDelay: .zero
        )
        model.subject = "Never mind"
        try await wait("the create to be in flight") { await api.parkedCreateCount == 1 }

        let discard = Task { await model.discard() }
        try await wait("the delete to be waiting for the create") { model.draftCreationWaiterCount == 1 }
        await api.releaseCreates()
        await discard.value

        #expect(await api.createdDrafts.count == 1)
        #expect(await api.deletedDraftIDs == ["draft-1"], "the discarded draft was left on the server")
    }

    /// Send (⌘⇧D) while the first save is still creating the server draft: the
    /// send waits and names the draft, so the server consumes it. Fails if the
    /// send goes out without a draft id while the create lands afterwards —
    /// the message sent AND an orphaned copy left in Drafts.
    @Test(.timeLimit(.minutes(1)))
    func sendDuringAnInFlightCreateNamesTheCreatedDraft() async throws {
        let api = await Self.composeAPI()
        await api.holdCreates()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: api),
            autosaveDelay: .zero
        )
        model.toText = "friend@example.com"
        try await wait("the create to be in flight") { await api.parkedCreateCount == 1 }
        // An edit's autosave parks behind the create too.
        model.bodyText = "Hello"
        try await wait("the edit's autosave to wait for the create") { model.draftCreationWaiterCount == 1 }

        let send = Task { await model.send() }
        try await wait("the send to wait for the create") { model.draftCreationWaiterCount == 2 }
        #expect(await api.sentInputs.isEmpty, "the send went out while the draft was still being created")
        await api.releaseCreates()
        #expect(await send.value)

        #expect(await api.createdDrafts.count == 1)
        let sent = try #require(await api.sentInputs.first)
        #expect(sent.draftID == "draft-1", "the send did not name the draft it consumed")
        #expect(sent.text == "Hello")
        // The parked autosave was cancelled by the Send: no PATCH may race the
        // send that consumes the draft (it would 404 onto the error bar). The
        // one PATCH is the send's own signature sync before `POST /send`; the
        // woken autosave made it two.
        #expect(await api.updatedDrafts.count == 1, "a parked autosave raced the send")
    }

    /// An upload onto a draft with no server id creates the draft first; if the
    /// upload itself then fails (a 413, a dropped link), the created draft's id
    /// must survive. Fails if the create happens inside `attach`, whose error
    /// throws the id away — the next save would create a second draft.
    @Test func anUploadThatFailsAfterCreatingTheDraftKeepsItsID() async throws {
        let api = await Self.composeAPI()
        await api.setAttachmentError(.server(code: "PAYLOAD_TOO_LARGE", message: "too big"))
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: OutboxService(api: api),
            autosaveDelay: .zero
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("d4-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await model.attach(file)
        #expect(model.status.message != nil, "the failed upload was not reported")
        #expect(model.draft.serverDraft?.id == "draft-1", "the failed upload lost the draft it created")

        model.subject = "After the failed upload"
        await model.waitForAutosave()
        #expect(await api.createdDrafts.count == 1, "a second server draft was created")
        #expect(await api.updatedDrafts.first?.subject == "After the failed upload")
    }

    /// The close sheet's Save Draft on a composer whose account was signed out:
    /// nothing can be saved, and it must SAY so. Fails if the press is silent
    /// (the bar already showed the send failure, so nothing changed and
    /// nothing was announced), or if the window closes over the only copy.
    @Test func saveDraftOnASignedOutComposerSaysWhy() async {
        let outbox = FakeOutbox()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .seconds(3600)
        )
        model.bodyText = "Keep me"
        model.accountSignedOut()
        let announced = model.announcementCount

        await model.saveAndClose()

        #expect(model.status.message == ComposeViewModel.accountSignedOutSaveReason)
        #expect(model.announcement == ComposeViewModel.accountSignedOutSaveReason)
        #expect(model.announcementCount > announced, "Save Draft did nothing a VoiceOver user could hear")
        #expect(model.isClosed == false)
        #expect(await outbox.saveCount == 0)

        // Pressed again: still heard, though the bar already says it.
        let again = model.announcementCount
        await model.saveAndClose()
        #expect(model.announcementCount > again)
    }

    /// Sign-out (and a re-auth that came back as a different user) must never
    /// let the window save or send through an account that is gone — and must
    /// not offer a Sign In that cannot bring it back. The text stays for the user
    /// to copy. Fails if Send still reaches the outbox, if autosave keeps
    /// running, or if the bar/tooltip say nothing about why.
    @Test func aSignedOutAccountsComposerKeepsItsTextAndNeverSends() async {
        let outbox = FakeOutbox()
        let model = ComposeViewModel(
            context: ComposeContext(kind: .new, fromAddress: "me@example.com"),
            outbox: outbox,
            autosaveDelay: .zero
        )
        model.toText = "friend@example.com"
        model.bodyText = "Keep me"
        await model.waitForAutosave()
        let saves = await outbox.saveCount

        model.accountSignedOut()
        model.bodyText = "Keep me, edited"
        await model.waitForAutosave()
        #expect(await model.send() == false)

        #expect(await outbox.sendCount == 0, "a signed-out account's composer sent")
        #expect(await outbox.saveCount == saves, "a signed-out account's composer kept autosaving")
        #expect(model.bodyText == "Keep me, edited")
        #expect(model.isSendBlocked)
        #expect(model.status.message == ComposeViewModel.accountSignedOutReason)
        #expect(model.sendHelp == ComposeViewModel.accountSignedOutReason)
        #expect(model.signInAffordance == .none)
        // A later sign-in of the same origin is a different graph; this window
        // stays orphaned rather than silently rebinding.
        model.accountSignedIn(outbox: FakeOutbox())
        #expect(model.isSendBlocked)
    }

    // MARK: - Survival across re-auth, through the environment

    /// The incident end to end, minus the browser: a send 401s, the account is
    /// re-installed (what a successful re-auth does), and the SAME composer —
    /// same instance, same text, same send key — sends through the NEW graph's
    /// client once the user presses Send again.
    ///
    /// Fails on the old `closeComposeSessions` on re-install: the session is
    /// gone (a scene rebuild shows "no longer available"), the error never
    /// clears, and the send goes to the superseded client.
    @Test func aComposerSurvivesReauthAndSendsThroughTheNewGraph() async throws {
        let environment = Self.environment()
        let store = try MailStore.inMemory()
        let oldAPI = await Self.composeAPI(dead: true)
        await environment.install(account: Self.a, api: oldAPI, store: store)
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let model = try #require(environment.makeComposeViewModel(id: id))
        model.toText = "friend@example.com"
        model.subject = "Quarterly"
        model.bodyText = "The only copy of this text is in the window"
        let key = model.draft.sendAttemptKey

        #expect(await model.send() == false)
        #expect(model.requiresSignIn)
        let oldCalls = await oldAPI.composeRequestCount

        let newAPI = await Self.composeAPI()
        await environment.install(account: Self.a, api: newAPI, store: store)

        #expect(environment.makeComposeViewModel(id: id) === model, "re-auth dropped the composer's session")
        #expect(model.requiresSignIn == false, "the dead-session error outlived the sign-in")
        #expect(model.status.message == nil)
        #expect(model.bodyText == "The only copy of this text is in the window")
        #expect(await newAPI.sentInputs.isEmpty, "signing in resent by itself")

        #expect(await model.send())
        let sent = try #require(await newAPI.sentInputs.first)
        #expect(sent.text == "The only copy of this text is in the window")
        #expect(sent.subject == "Quarterly")
        #expect(sent.idempotencyKey == key, "the retry after a 401 changed identity")
        #expect(await oldAPI.composeRequestCount == oldCalls, "the superseded client was used after re-auth")
    }

    /// The Drafts folder must hear about a post-re-auth autosave on the
    /// account's CURRENT view-model — the superseded one is stopped and nobody
    /// is looking at it. Fails if the event goes to the stopped graph (the
    /// Drafts list would lag until the next poll).
    @Test func draftCacheEventsAfterReauthReachTheNewGraph() async throws {
        let environment = Self.environment()
        let store = try MailStore.inMemory()
        await environment.install(account: Self.a, api: await Self.composeAPI(dead: true), store: store)
        let oldMail = try #require(environment.graphs[Self.a.id]?.mail)
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let model = try #require(environment.makeComposeViewModel(id: id))
        model.subject = "Draft after re-auth"
        await model.saveNow()
        #expect(model.requiresSignIn)

        await environment.install(account: Self.a, api: await Self.composeAPI(), store: store)
        let newMail = try #require(environment.graphs[Self.a.id]?.mail)
        #expect(newMail !== oldMail)
        await model.saveNow()
        let draftID = try #require(model.draft.serverDraft?.id)

        try await wait("the new graph's Drafts list to show the autosave") {
            newMail.drafts.contains { $0.id == draftID }
        }
        #expect(!oldMail.drafts.contains { $0.id == draftID }, "the event went to the superseded graph")
    }

    /// Per account, in both directions. Re-authenticating A must not touch B's
    /// composer — B's session is still dead, so its Sign In must stay and its
    /// send must still go to B's own client — and B's composer reports B's
    /// attempt state, not whichever account is selected.
    @Test func anotherAccountsComposerIsUntouchedByThisAccountsReauth() async throws {
        let environment = Self.environment()
        let store = try MailStore.inMemory()
        let apiA = await Self.composeAPI(dead: true)
        let apiB = await Self.composeAPI(dead: true)
        await environment.install(account: Self.a, api: apiA, store: store)
        let idA = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        await environment.install(account: Self.b, api: apiB, store: store)
        let idB = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        #expect(environment.composeAccountID(for: idA) == Self.a.id)
        #expect(environment.composeAccountID(for: idB) == Self.b.id)
        let modelA = try #require(environment.makeComposeViewModel(id: idA))
        let modelB = try #require(environment.makeComposeViewModel(id: idB))
        for model in [modelA, modelB] {
            model.toText = "friend@example.com"
            model.bodyText = "Hello"
            #expect(await model.send() == false)
            #expect(model.requiresSignIn)
        }

        // An attempt for A while B is SELECTED: only A's composer shows it.
        #expect(environment.selectedAccountID == Self.b.id)
        let claimed = environment.autoReauth.beginUserInitiated(accountID: Self.a.id)
        #expect(claimed)
        #expect(modelA.signInAffordance == .inProgress)
        #expect(modelB.signInAffordance == .available, "B's composer followed A's attempt")
        environment.autoReauth.finish(accountID: Self.a.id, succeeded: true)

        let newA = await Self.composeAPI()
        await environment.install(account: Self.a, api: newA, store: store)

        #expect(modelA.requiresSignIn == false)
        #expect(modelB.requiresSignIn, "A's re-auth cleared B's dead-session error")
        #expect(environment.makeComposeViewModel(id: idB) === modelB)
        let bCalls = await apiB.composeRequestCount
        #expect(await modelB.send() == false)
        #expect(await apiB.composeRequestCount == bCalls + 1, "B's composer stopped using B's client")
        #expect(await newA.composeRequestCount == 0, "B's composer was rebound to A's new client")
    }

    /// The button itself, through the REAL re-auth round trip (scripted
    /// browser, `OAuthTestServer`): it signs in the composer's OWN account even
    /// while another account is selected, shows progress while the window is up,
    /// and when consent completes the same composer is back with its text and no
    /// error. Fails if Sign In targets the selected account, or if the install
    /// the round trip ends in strands the composer.
    @Test func theComposersSignInReauthenticatesItsOwnAccount() async throws {
        let api = await Self.composeAPI(dead: true)
        let h = try await ReauthCancelTests.harness(api: api, also: [ReauthCancelTests.other])
        let environment = h.environment
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        #expect(environment.composeAccountID(for: id) == h.accountID)
        let model = try #require(environment.makeComposeViewModel(id: id))
        model.toText = "friend@example.com"
        model.bodyText = "Still here after signing in"
        #expect(await model.send() == false)
        #expect(model.signInAffordance == .available)

        environment.selectAccount(ReauthCancelTests.other.id)
        let signIn = Task { await model.signIn() }
        try await wait("the composer's sign-in to reach the browser") { h.presenter.attemptCount == 1 }
        #expect(environment.isReauthenticating(accountID: h.accountID), "Sign In ran for the wrong account")
        #expect(environment.isReauthenticating(accountID: ReauthCancelTests.other.id) == false)
        #expect(model.signInAffordance == .inProgress)
        #expect(model.announcement == "Signing in. Your message stays in this window.")

        h.presenter.releaseAll()
        await signIn.value

        #expect(environment.graphs[h.accountID] !== h.graph, "the sign-in did not install a new graph")
        #expect(environment.makeComposeViewModel(id: id) === model)
        #expect(model.signInAffordance == .none)
        #expect(model.status.message == nil)
        #expect(model.bodyText == "Still here after signing in")
        #expect(model.isClosed == false, "signing in must not send by itself")
        // AFTER the install: the composer's Sign In repaired a background
        // account, and the window stays on the one the user is reading (W8).
        #expect(environment.selectedAccountID == ReauthCancelTests.other.id, "the composer's Sign In took the window")
        await environment.stopGraph(accountID: h.accountID)
    }

    /// Sign-out is NOT a re-auth: the composer's session goes, its view-model is
    /// blocked (never rebound), and a window rebuild keeps showing the text.
    /// Fails if a signed-out account's composer can still reach its client, or
    /// offers a Sign In that `reauthenticate` would ignore (no graph).
    @Test func signingOutBlocksTheComposerInsteadOfRebindingIt() async throws {
        let environment = Self.environment()
        let store = try MailStore.inMemory()
        let apiA = await Self.composeAPI(dead: true)
        await environment.install(account: Self.a, api: apiA, store: store)
        await environment.install(account: Self.b, api: FakeMailAPIClient(), store: store, select: false)
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        let model = try #require(environment.makeComposeViewModel(id: id))
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        #expect(await model.send() == false)
        #expect(model.requiresSignIn)

        await environment.signOut(accountID: Self.a.id)
        let calls = await apiA.composeRequestCount

        #expect(environment.composeAccountID(for: id) == nil)
        #expect(model.isAccountSignedOut)
        #expect(model.signInAffordance == .none, "a Sign In for a signed-out account does nothing")
        #expect(await model.send() == false)
        #expect(await apiA.composeRequestCount == calls, "a signed-out account's composer reached its server")
        #expect(model.bodyText == "Hello")
    }

    /// A send from A's composer syncs A — not the selected account B — right
    /// away. Measured as a sync pass (`listMailboxes`) on each account's own
    /// server after both initial passes settle; the idle poll is minutes away,
    /// so a new pass within the timeout can only be the refresh. Fails if the
    /// send triggers no pass (the reply waits for the poll) or syncs B.
    @Test func anAcceptedSendSyncsTheComposingAccountNow() async throws {
        let environment = Self.environment()
        let store = try MailStore.inMemory()
        let apiA = await Self.composeAPI()
        let apiB = await Self.composeAPI()
        await environment.install(account: Self.a, api: apiA, store: store)
        let id = try #require(await environment.prepareCompose(ComposeRequest(kind: .new)))
        await environment.install(account: Self.b, api: apiB, store: store)
        #expect(environment.selectedAccountID == Self.b.id)
        try await wait("both initial passes") {
            let a = await apiA.mailboxRequestCount; let b = await apiB.mailboxRequestCount; return a > 0 && b > 0
        }
        // Let any in-flight pass finish before taking the baseline.
        try await Task.sleep(for: .milliseconds(200))
        let baseA = await apiA.mailboxRequestCount
        let baseB = await apiB.mailboxRequestCount

        let model = try #require(environment.makeComposeViewModel(id: id))
        model.toText = "friend@example.com"
        model.bodyText = "Hello"
        #expect(await model.send())

        try await wait("A's sync pass after the send") {
            await apiA.mailboxRequestCount > baseA
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await apiB.mailboxRequestCount == baseB, "the send synced the selected account, not the composing one")
    }
}
