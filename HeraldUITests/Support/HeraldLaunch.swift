import XCTest

/// The UI-test launch contract (mirror of `Herald/UITestSupport/UITestLaunch.swift`,
/// which this bundle cannot import). The app REFUSES an unknown value with a
/// `fatalError`, so a typo here fails loudly at launch rather than falling
/// back to the real Keychain and network.
enum UITestScenario: String, Sendable {
    /// No accounts: the onboarding screen.
    case signedOut
    /// One account on `https://hqbase.uitest.invalid` with five Inbox messages.
    case oneAccount
    /// Two accounts on two different fake origins.
    case twoAccounts
}

/// The fake HQBase's behaviour (`FakeHQBaseState`).
enum UITestServerState: String, Sendable, CaseIterable {
    case healthy
    case deadSession140
    case invalidGrant
    case bareTokenEndpoint401
    case invalidClient
}

/// The scripted sign-in window's behaviour (`SignInPresenterMode`).
enum UITestPresenterMode: Sendable, Equatable {
    case succeed
    case hangUntilCancelled
    case userCancel
    /// `nil` = the harness's default failure reason.
    case fail(String? = nil)

    /// The `-HeraldUITestPresenter` value.
    var argument: String {
        switch self {
        case .succeed: "succeed"
        case .hangUntilCancelled: "hangUntilCancelled"
        case .userCancel: "userCancel"
        case .fail(let reason): reason.map { "fail:\($0)" } ?? "fail"
        }
    }

    /// What `uitest.status` reports as `presenter=` (the reason is not in it).
    var statusName: String {
        switch self {
        case .succeed: "succeed"
        case .hangUntilCancelled: "hangUntilCancelled"
        case .userCancel: "userCancel"
        case .fail: "fail"
        }
    }
}

/// Launches Herald in UI-test mode. EVERY launch goes through here: a launch
/// without `-HeraldUITest` would be the real app on the real Keychain.
@MainActor
enum HeraldApp {
    /// Default wait for anything the app has to draw after launch or a click.
    static let defaultTimeout: TimeInterval = 10

    static func launchArguments(
        scenario: UITestScenario,
        server: UITestServerState = .healthy,
        presenter: UITestPresenterMode = .succeed
    ) -> [String] {
        [
            "-HeraldUITest", scenario.rawValue,
            "-HeraldUITestServer", server.rawValue,
            "-HeraldUITestPresenter", presenter.argument,
            // AppKit state restoration writes into the REAL defaults domain
            // (Debug and Release share the bundle id) and would reopen windows
            // from the previous run: off, both of them.
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
    }

    /// Launches (terminating any previous instance first — `XCUIApplication`
    /// does that itself), brings the app forward and waits for its first
    /// window. The caller terminates it (``HeraldUITestCase`` does, in tearDown).
    @discardableResult
    static func launch(
        scenario: UITestScenario,
        server: UITestServerState = .healthy,
        presenter: UITestPresenterMode = .succeed
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(scenario: scenario, server: server, presenter: presenter)
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: defaultTimeout),
            "Herald launched (\(scenario.rawValue)) but no window appeared"
        )
        return app
    }
}

/// Base class: launches through ``HeraldApp`` and ALWAYS terminates the app
/// afterwards, so no test leaves a Herald running for the next one (or for
/// the user) to trip over.
@MainActor
class HeraldUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try await super.tearDown()
    }

    @discardableResult
    func launch(
        _ scenario: UITestScenario,
        server: UITestServerState = .healthy,
        presenter: UITestPresenterMode = .succeed
    ) -> XCUIApplication {
        let launched = HeraldApp.launch(scenario: scenario, server: server, presenter: presenter)
        app = launched
        return launched
    }

    // Page objects over the current app.
    var banner: BannerPage { BannerPage(app: app) }
    var sidebar: SidebarPage { SidebarPage(app: app) }
    var mailList: MailListPage { MailListPage(app: app) }
    var compose: ComposePage { ComposePage(app: app) }
    var onboarding: OnboardingPage { OnboardingPage(app: app) }
    var controls: TestControlsPage { TestControlsPage(app: app) }
    var alerts: AlertsPage { AlertsPage(app: app) }
}
