import Foundation
import HeraldKit
import Testing
@testable import Herald

/// Debug builds are a separate app to macOS (audit U6a): their own bundle id, OAuth
/// callback scheme, sandbox container and Keychain namespace, so a dev copy or a
/// UI-test run can never terminate, sign out or steal callbacks from the release app.
/// These run in the Debug test host; the Release identity is verified on the exported
/// app by scripts/release.sh (`scripts/verify-release-identity.sh`).
@Suite struct DebugIdentityTests {
    private static let releaseID = "com.wizemann.herald"
    private static let debugID = "com.wizemann.herald.debug"

    /// Fails if the Debug configuration's bundle id override is dropped from
    /// project.yml — the dev copy would be the release app again.
    @Test func theDebugHostHasItsOwnBundleID() {
        #expect(Bundle.main.bundleIdentifier == Self.debugID)
    }

    /// The scheme the app REGISTERS (Info.plist, from the bundle id) must be the one
    /// HeraldKit hands to ASWebAuthenticationSession and puts in the redirect URI —
    /// otherwise the browser's callback never comes back to this app. Fails if either
    /// side is changed without the other.
    @Test func theRegisteredURLSchemeIsTheOAuthCallbackScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [Self.debugID])
        #expect(DynamicClientRegistration.callbackScheme == Self.debugID)
        #expect(DynamicClientRegistration.redirectURI.absoluteString == "\(Self.debugID):/oauth/callback")
    }

    /// The dev copy's secrets never share the release app's Keychain items (or the
    /// pre-U6a dev copy's `.debug` items, which carry a client registered for the
    /// release redirect).
    @Test func theKeychainNamespaceIsTheDevOne() {
        #expect(KeychainStore.defaultService == "com.wizemann.herald.dev")
        #expect(KeychainStore.defaultService != Self.releaseID)
    }

    /// Sparkle never starts in a Debug build, arguments or not: the appcast only
    /// carries the Developer ID release, which is not an update for a dev copy.
    /// Fails if the Debug gate is removed.
    @Test func debugBuildsNeverStartTheUpdater() {
        #expect(UpdateService.isDebugBuild)
        #expect(UpdateService.startsUpdater(arguments: ["Herald"], isRunningUnderTests: false) == false)
        // Control: the same arguments in a release build do start it.
        #expect(UpdateService.startsUpdater(arguments: ["Herald"], isRunningUnderTests: false, isDebugBuild: false))
    }
}
