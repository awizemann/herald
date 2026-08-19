import Foundation
import OSLog
import SwiftUI

#if canImport(Sparkle)
import Combine
import Sparkle
#endif

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "UpdateService")

/// Sparkle 2 auto-update integration (t-8a1c0026). Owns the single
/// `SPUStandardUpdaterController` for the app's lifetime and vends the app-menu
/// "Check for Updates…" item, so no caller ever touches a Sparkle type.
///
/// THE GUARD IS THE POINT. Sparkle's updater aborts at `start` when the bundle has no
/// usable `SUPublicEDKey` — which is exactly the state of every unsigned build: CI, a
/// fresh clone before the owner mints the keypair, and the `swift test` / xcodebuild-test
/// runs (whose host IS this app). So `isAvailable` is decided FIRST, from the Info
/// dictionary, and the updater is only constructed when the key is real. When it isn't,
/// we log a warning once and the menu item is present but disabled.
///
/// Sandbox: installing an update runs outside the sandbox via Sparkle's bundled Installer
/// XPC service — enabled by `SUEnableInstallerLauncherService` (Info.plist) plus the
/// -spks/-spki mach-lookup exceptions (Herald.entitlements). Downloads run in-process
/// (we hold `network.client`), so the Downloader XPC service is not enabled.
@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService()

    /// The Info.plist key carrying the EdDSA public half that verifies update signatures.
    nonisolated static let publicKeyInfoKey = "SUPublicEDKey"

    /// True when the bundle carries a real signing key, i.e. when updates can work at all.
    /// The menu item binds to this; nothing else in the app has to know why.
    let isAvailable: Bool

    /// Whether a live updater was constructed. Distinct from `isAvailable` only under tests
    /// and in the no-Sparkle build; it exists so a test can assert that the placeholder path
    /// never reaches Sparkle, which is otherwise invisible.
    private(set) var didStartUpdater = false

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController?
    #endif

    /// - Parameters:
    ///   - info: the bundle's Info dictionary. Injected so the placeholder-key decision is
    ///     deterministic in tests instead of depending on how the host was built.
    ///   - startsUpdater: `false` keeps a real key from spinning up a live updater (background
    ///     appcast fetches would break test hermeticity — the app-hosted suites run inside
    ///     this very app).
    init(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        startsUpdater: Bool = !ProcessInfo.processInfo.isRunningUnderTests
    ) {
        isAvailable = Self.hasUsableSigningKey(in: info)

        #if canImport(Sparkle)
        if isAvailable, startsUpdater {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            didStartUpdater = true
        } else {
            updaterController = nil
            if !isAvailable {
                logger.warning(
                    "\(Self.publicKeyInfoKey, privacy: .public) is missing or a placeholder — auto-update disabled. Run ./scripts/sparkle-keys.sh and paste the key into project.yml."
                )
            }
        }
        #else
        logger.warning("Sparkle is not linked — auto-update disabled.")
        #endif
    }

    /// A bundle can check for updates only when it ships a well-formed ed25519 public key:
    /// 32 bytes, base64. The generated placeholder (and an empty or absent value) fails here,
    /// which is what keeps unsigned builds from constructing an updater that would abort.
    nonisolated static func hasUsableSigningKey(in info: [String: Any]) -> Bool {
        guard let key = info[publicKeyInfoKey] as? String else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.uppercased().contains("PLACEHOLDER") else { return false }
        return Data(base64Encoded: trimmed)?.count == 32
    }

    /// Ask Sparkle to check now. A no-op when updates are unavailable; the menu item is
    /// disabled in that state, so this only guards programmatic callers.
    func checkForUpdates() {
        #if canImport(Sparkle)
        guard let updaterController else {
            logger.warning("checkForUpdates() ignored — no updater (unsigned or test build).")
            return
        }
        updaterController.updater.checkForUpdates()
        #else
        logger.warning("checkForUpdates() ignored — Sparkle is not linked.")
        #endif
    }

    /// Live enablement. Sparkle flips its own `canCheckForUpdates` to true asynchronously
    /// after launch and back to false while a check is in flight, so this must be read
    /// reactively (see `checkForUpdatesMenuItem`), never latched at menu-build time.
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        updaterController?.updater.canCheckForUpdates ?? false
        #else
        false
        #endif
    }

    /// The app-menu "Check for Updates…" item. Owned here so `MailCommands` never sees a
    /// Sparkle type and needs no `#if`.
    /// - Parameter record: called when the user picks the item. Injected rather
    ///   than reached for through a singleton: this service IS one, and analytics
    ///   must not become a second.
    @ViewBuilder
    func checkForUpdatesMenuItem(
        record: @escaping @MainActor @Sendable () -> Void = {}
    ) -> some View {
        #if canImport(Sparkle)
        if let updaterController {
            CheckForUpdatesView(updater: updaterController.updater, record: record)
        } else {
            Button("Check for Updates…") {}.disabled(true)
        }
        #else
        Button("Check for Updates…") {}.disabled(true)
        #endif
    }
}

#if canImport(Sparkle)
/// Reactive menu item: observes Sparkle's KVO `canCheckForUpdates` so the item enables the
/// moment the updater is ready and disables while a check runs. A static
/// `.disabled(!canCheckForUpdates)` read once at menu-build time would latch disabled
/// forever. Canonical Sparkle SwiftUI pattern.
private struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater
    private let record: @MainActor @Sendable () -> Void

    init(updater: SPUUpdater, record: @escaping @MainActor @Sendable () -> Void) {
        self.updater = updater
        self.model = CheckForUpdatesModel(updater: updater)
        self.record = record
    }

    var body: some View {
        // Only the EXPLICIT check is reported; Sparkle's background checks are
        // not something the user did.
        Button("Check for Updates…") {
            record()
            updater.checkForUpdates()
        }
            .disabled(!model.canCheckForUpdates)
    }
}

@MainActor
private final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
#endif

extension ProcessInfo {
    /// Covers BOTH XCTest and Swift Testing: Swift Testing leaves `XCTestConfigurationFilePath`
    /// unset when it runs standalone, so checking that alone would miss this project's suites.
    nonisolated var isRunningUnderTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
