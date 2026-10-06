import Foundation
import Stats
import StatsTesting
import Testing
@testable import Herald

/// What Herald's install identity actually is, and what it discloses about it.
///
/// Both halves of one promise: the configuration grants `.identity`, so an install
/// keeps one id across launches — and therefore the privacy manifest must declare
/// Device ID. Either half changing without the other is a privacy bug.
@Suite struct UsageIdentityTests {

    /// Runs Herald's REAL configuration (``UsageAnalytics/configuration(sink:)``)
    /// through two launches. Fails if the consent ever loses `.identity` — every
    /// session would then look like a new install and active-install counts
    /// would silently become session counts. `RelaunchProbe` isolates itself
    /// under a random app id and temporary storage, so this never touches the
    /// real app's queue or identity suite.
    @Test func heraldsConfigurationKeepsOneInstallIdAcrossARelaunch() async throws {
        let configuration = UsageAnalytics.configuration(sink: InMemorySink())
        let probe = try #require(await RelaunchProbe.installIDsAcrossRelaunch(configuration: configuration))
        #expect(probe.isInstallIdStable)
        #expect(probe.seqAfterRelaunch > probe.seqBeforeRelaunch, "a relaunch continues the install, not a new one")
    }

    /// The control: the same probe with identity denied DOES change the id, so the
    /// test above can tell the two configurations apart rather than passing on any.
    @Test func withoutIdentityTheProbeSeesANewInstall() async throws {
        var configuration = UsageAnalytics.configuration(sink: InMemorySink())
        configuration.consent = [.usage, .diagnostics]
        let probe = try #require(await RelaunchProbe.installIDsAcrossRelaunch(configuration: configuration))
        #expect(!probe.isInstallIdStable)
    }

    /// The bundled manifest must match what the SDK collects under that
    /// configuration (swift-stats 0.3.0, setup guide §7): Product Interaction,
    /// Other Diagnostic Data and Device ID, none linked (Herald never calls
    /// `identify`), none tracking, and no User ID. Fails if Device ID is dropped,
    /// anything is marked linked, or a User ID is declared without `identify`.
    @Test func privacyManifestDeclaresExactlyWhatTheSDKCollects() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        #expect(plist["NSPrivacyTracking"] as? Bool == false)

        let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(types == [
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeDeviceID",
        ])
        let deviceID = try #require(collected.first {
            $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeDeviceID"
        })
        #expect(deviceID["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAnalytics"])
        for entry in collected {
            let type = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == false, "\(type) must not be linked")
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false, "\(type) must not track")
        }
    }
}
