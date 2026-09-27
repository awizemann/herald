import XCTest

/// Multi-page flows the session-recovery scenarios share (U3/U4). Each one
/// asserts the step it is responsible for, so a scenario test failing inside
/// a flow names the step that broke, not only the scenario.
@MainActor
extension HeraldUITestCase {
    /// What the composers in these scenarios type. Distinct strings, so an
    /// "intact after sign-in" check cannot pass on a stray default value.
    enum Draft {
        static let to = "someone@hqbase.uitest.invalid"
        static let subject = "Recovery scenario subject"
        static let body = "Typed before the session died."
    }

    /// Longer than the composer's 2 s autosave debounce: a draft whose save
    /// counters have not moved for this long, with no save in flight, has no
    /// autosave pending either.
    static let autosaveQuietPeriod: TimeInterval = 3

    /// Opens a composer, fills To/Subject/Body, and waits until autosave is
    /// QUIET on the (still healthy) server — the first save landed, and no
    /// save is pending or in flight — so a session killed afterwards is found
    /// by the test's own next action, never by a debounced PATCH racing it.
    @discardableResult
    func openFilledComposer(file: StaticString = #filePath, line: UInt = #line) -> ComposePage {
        let page = ComposePage.openNew(in: app, file: file, line: line)
        page.fill(to: Draft.to, subject: Draft.subject, body: Draft.body, file: file, line: line)
        XCTAssertNotNil(
            controls.waitForCount("draftCreates", atLeast: 1),
            "the composer's first autosave never reached the server", file: file, line: line
        )
        XCTAssertTrue(
            waitForAutosaveQuiet(page),
            "autosave never went quiet: \(controls.currentStatus()?.description ?? "no status")", file: file, line: line
        )
        // The save counter is live (so a later "no save attempted" means something).
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(controls.currentStatus()?.saveAttempts, "no parseable uitest.status", file: file, line: line), 1,
            "saves reached the server but none was counted as attempted", file: file, line: line
        )
        return page
    }

    /// Waits until the composer's saves have been still for
    /// ``autosaveQuietPeriod``: `draftCreates`, `draftUpdates` and
    /// `saveAttempts` unchanged, and no `compose.busy` (a save in flight)
    /// throughout. A missing or unparseable status restarts the clock — it
    /// never counts as quiet.
    func waitForAutosaveQuiet(_ page: ComposePage, timeout: TimeInterval = 20) -> Bool {
        var last: [Int]?
        var quietSince = Date()
        return Wait.until(timeout: timeout) {
            let status = controls.currentStatus()
            let now = [status?.draftCreates, status?.draftUpdates, status?.saveAttempts].compactMap { $0 }
            guard now.count == 3, !page.busy.exists, now == last else {
                last = now.count == 3 ? now : nil
                quietSince = Date()
                return false
            }
            return Date().timeIntervalSince(quietSince) >= Self.autosaveQuietPeriod
        }
    }

    /// Kills the session on the fake server (HQBase 1.4.0's dead web session:
    /// resource calls 401, refresh 200 minting tokens that 401 too).
    func killSession(file: StaticString = #filePath, line: UInt = #line) {
        controls.setServer(.deadSession140, file: file, line: line)
    }

    /// Makes the main window talk to the server now (toolbar Refresh), so a
    /// dead session is found without waiting for the 15 s poll.
    func refreshMail(file: StaticString = #filePath, line: UInt = #line) {
        mailList.refreshButton.waitAndClick(file: file, line: line)
    }

    /// Kills the session and has the main window find it: the re-auth banner
    /// comes up. Used by the scenarios that start from "the account needs
    /// signing in" rather than from a send.
    func killSessionAndWaitForBanner(file: StaticString = #filePath, line: UInt = #line) {
        killSession(file: file, line: line)
        refreshMail(file: file, line: line)
        XCTAssertTrue(
            banner.container.waitUntilExists(),
            "a refresh against a dead session never raised the re-auth banner", file: file, line: line
        )
    }

    /// The text the composer holds right now, field by field.
    func composerText(_ page: ComposePage) -> (to: String, subject: String, body: String) {
        (page.to.stringValue, page.subject.stringValue, page.body.stringValue)
    }
}
