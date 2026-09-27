#if DEBUG
import Foundation

/// The launch-argument contract of the Debug-only UI-test mode.
///
/// Test mode exists only when BOTH hold: the build is Debug (this whole folder
/// is `#if DEBUG`, so a Release binary has no trace of it) AND the process was
/// launched with ``scenarioArgument`` followed by a scenario name:
///
///     Herald -HeraldUITest oneAccount [-HeraldUITestServer deadSession140]
///            [-HeraldUITestPresenter hangUntilCancelled|fail:<reason>]
///
/// A present-but-malformed request (no scenario, an unknown scenario, server
/// state or presenter mode) is REFUSED rather than ignored: falling back to the
/// real composition root would put a UI test in front of the real Keychain and
/// the real network. ``HeraldApp`` stops the launch on it.
nonisolated struct UITestLaunchConfiguration: Sendable, Equatable {
    static let scenarioArgument = "-HeraldUITest"
    static let serverArgument = "-HeraldUITestServer"
    static let presenterArgument = "-HeraldUITestPresenter"

    /// What the app starts with.
    enum Scenario: String, Sendable, CaseIterable {
        /// No accounts: the onboarding screen.
        case signedOut
        /// One account on ``UITestOrigins/primary`` with a handful of Inbox messages.
        case oneAccount
        /// Two accounts on two DIFFERENT origins (identity is origin-keyed).
        case twoAccounts
    }

    var scenario: Scenario
    var serverState: FakeHQBaseState = .healthy
    var presenterMode: SignInPresenterMode = .succeed

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownScenario(String)
        case unknownServerState(String)
        case unknownPresenterMode(String)

        var description: String {
            switch self {
            case .missingValue(let flag): "\(flag) needs a value"
            case .unknownScenario(let value):
                "unknown UI-test scenario '\(value)' (expected one of: \(Scenario.allCases.map(\.rawValue).joined(separator: ", ")))"
            case .unknownServerState(let value):
                "unknown UI-test server state '\(value)' (expected one of: \(FakeHQBaseState.allCases.map(\.rawValue).joined(separator: ", ")))"
            case .unknownPresenterMode(let value):
                "unknown UI-test presenter mode '\(value)' (expected succeed, hangUntilCancelled, userCancel, fail or fail:<reason>)"
            }
        }
    }

    /// Whether the process asked for test mode at all — true even when the
    /// request is malformed. Used by the pieces that must stand down before
    /// the harness exists (Sparkle, analytics).
    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(scenarioArgument)
    }

    /// `nil` when test mode was not requested; throws when it was requested
    /// badly. Only the FIRST argument vector entry after each flag is read.
    static func parse(arguments: [String]) throws -> UITestLaunchConfiguration? {
        guard isRequested(in: arguments) else { return nil }
        guard let scenarioName = value(after: scenarioArgument, in: arguments) else {
            throw ParseError.missingValue(scenarioArgument)
        }
        guard let scenario = Scenario(rawValue: scenarioName) else {
            throw ParseError.unknownScenario(scenarioName)
        }
        var configuration = UITestLaunchConfiguration(scenario: scenario)
        if arguments.contains(serverArgument) {
            guard let raw = value(after: serverArgument, in: arguments) else {
                throw ParseError.missingValue(serverArgument)
            }
            guard let state = FakeHQBaseState(rawValue: raw) else { throw ParseError.unknownServerState(raw) }
            configuration.serverState = state
        }
        if arguments.contains(presenterArgument) {
            guard let raw = value(after: presenterArgument, in: arguments) else {
                throw ParseError.missingValue(presenterArgument)
            }
            guard let mode = SignInPresenterMode(argument: raw) else { throw ParseError.unknownPresenterMode(raw) }
            configuration.presenterMode = mode
        }
        return configuration
    }

    /// The token after `flag`, unless it is missing or is itself a flag.
    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") || value.isEmpty ? nil : value
    }
}

/// The fake servers' origins. `.invalid` (RFC 2606) can never resolve, so a
/// request that somehow escaped the fake transport fails instead of reaching
/// anything real.
nonisolated enum UITestOrigins {
    static let primary = URL(string: "https://hqbase.uitest.invalid")!
    static let secondary = URL(string: "https://second.uitest.invalid")!
}
#endif
