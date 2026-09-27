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

    /// Opens a composer, fills To/Subject/Body, and waits for the first
    /// autosave to land on the (still healthy) server — so a session killed
    /// afterwards is found by the test's own next action, not by a debounced
    /// autosave racing it.
    @discardableResult
    func openFilledComposer(file: StaticString = #filePath, line: UInt = #line) -> ComposePage {
        let page = ComposePage.openNew(in: app, file: file, line: line)
        page.fill(to: Draft.to, subject: Draft.subject, body: Draft.body, file: file, line: line)
        XCTAssertNotNil(
            controls.waitForCount("draftCreates", atLeast: 1),
            "the composer's first autosave never reached the server", file: file, line: line
        )
        return page
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
