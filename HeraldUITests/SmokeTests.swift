import XCTest

/// The UI-test plumbing works end to end: each scenario launches into the
/// screen it promises, and the harness's control surface is reachable.
/// Scenario tests (dead session, recovery, compose) build on these helpers.
@MainActor
final class SmokeTests: HeraldUITestCase {
    /// The seeded Inbox of `FakeHQBase.seedInbox`.
    static let seededSubjects = [
        "Quarterly numbers", "Compiler notes", "Lunch on Friday?", "Substitution", "Shortest paths",
    ]

    func testOneAccountShowsTheSeededInbox() {
        launch(.oneAccount)

        XCTAssertTrue(
            mailList.waitForRows(subjects: Self.seededSubjects),
            "the inbox never showed all seeded subjects; rows: \(mailList.rows.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(mailList.composeButton.exists, "the toolbar's New Message button has no identifier")
        XCTAssertTrue(sidebar.status.waitUntilExists(), "the sidebar status slot is missing")
        XCTAssertFalse(banner.container.exists, "a healthy account shows the re-auth banner")
        XCTAssertFalse(onboarding.origin.exists, "a signed-in account shows onboarding")
    }

    func testSignedOutShowsOnboarding() {
        launch(.signedOut)

        XCTAssertTrue(onboarding.waitUntilVisible(), "onboarding never appeared")
        XCTAssertTrue(onboarding.signIn.exists, "onboarding has no Sign In")
        XCTAssertFalse(onboarding.signIn.isEnabled, "Sign In is enabled with no server address")
        XCTAssertFalse(mailList.row(subject: "Quarterly numbers").exists, "a signed-out launch shows mail")
    }

    func testUITestControlsAndStatusAreReachable() throws {
        launch(.oneAccount)

        let status = try XCTUnwrap(
            controls.waitForStatus(),
            "uitest.status never produced a parseable value (got \"\(controls.statusElement.stringValue)\")"
        )
        XCTAssertEqual(status.server, "healthy")
        XCTAssertEqual(status.presenter, "succeed")
        for key in UITestStatus.requiredKeys where !["server", "presenter", "storeRefusesList"].contains(key) {
            XCTAssertNotNil(status.count(key), "\(key) is not an integer in \(status)")
        }
        XCTAssertEqual(status.storeRefusesList, false)

        controls.open()
        let reset = controls.item(id: "uitest.resetCounters", title: "Reset counters")
        XCTAssertTrue(reset.waitUntilExists(), "the UI Test Controls menu has no Reset counters item")
        controls.closeMenu()

        // A round trip through the menu the status reflects.
        controls.setPresenter(.hangUntilCancelled)
        controls.setPresenter(.succeed)
    }
}
