import Foundation
import Testing
@testable import Herald

/// Sparkle's updater ABORTS at `start` when the bundle has no usable `SUPublicEDKey`, so the
/// placeholder path is the difference between "menu item is disabled" and "the app dies on
/// launch in CI and in every unsigned build". These tests pin that decision.
@MainActor
@Suite struct UpdateServiceTests {
    /// A real-shaped key: 32 bytes, base64 — the shape `generate_keys` emits.
    private static let realKey = Data(repeating: 7, count: 32).base64EncodedString()

    /// Fails if the placeholder in project.yml is ever treated as a signing key — which is the
    /// exact state of a fresh clone, so shipping that regression would crash every new build
    /// the moment Sparkle's updater started.
    @Test func placeholderKeyDisablesUpdatesAndNeverConstructsTheUpdater() {
        let service = UpdateService(info: ["SUPublicEDKey": "<PLACEHOLDER-SEE-README>"])

        #expect(service.isAvailable == false)
        #expect(service.didStartUpdater == false)
        #expect(service.canCheckForUpdates == false)
    }

    /// The other half of the same decision: a well-formed key must NOT be rejected, or the
    /// signed release would ship with updates silently switched off and no one would notice
    /// until an update failed to arrive.
    @Test func wellFormedKeyMakesUpdatesAvailable() {
        let service = UpdateService(info: ["SUPublicEDKey": Self.realKey], startsUpdater: false)

        #expect(service.isAvailable)
        // startsUpdater: false — a live updater would fetch the appcast over the network from
        // inside the test host.
        #expect(service.didStartUpdater == false)
    }

    /// Each of these has been a real way to get a broken key into a bundle: the key dropped
    /// from the plist entirely, an empty string left after a bad sed, and a truncated/padded
    /// value that is valid base64 but not an ed25519 key.
    @Test(arguments: [
        [:],
        ["SUPublicEDKey": ""],
        ["SUPublicEDKey": "   "],
        ["SUPublicEDKey": "not base64!!"],
        ["SUPublicEDKey": Data(repeating: 7, count: 16).base64EncodedString()],
    ] as [[String: String]])
    func malformedKeysAreRejected(info: [String: String]) {
        #expect(UpdateService.hasUsableSigningKey(in: info) == false)
    }

    /// The sandboxed Sparkle installer only works with both mach-lookup exceptions present,
    /// and an entitlements file that doesn't parse fails the build late and cryptically.
    /// Fails if either exception is dropped or the plist is malformed.
    @Test func entitlementsParseAndCarryTheSparkleMachLookupExceptions() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HeraldTests
            .deletingLastPathComponent()   // repo root
            .appending(path: "Herald/Herald.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let exceptions = plist["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String]
        #expect(exceptions == ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"])
        // The Downloader XPC service is deliberately absent — Sparkle downloads in-process.
        #expect(plist["com.apple.security.network.client"] as? Bool == true)
    }
}
