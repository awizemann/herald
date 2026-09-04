import Foundation
import Testing
@testable import HeraldKit

/// The wake socket against a REAL HQBase server.
///
/// Skipped unless the environment names one, so `swift test` stays hermetic. To
/// run it against the local 1.3.4 instance (see the operations note "HQBase Local
/// Test Instance"):
///
/// ```
/// HERALD_LIVE_ORIGIN=http://localhost:8787 \
/// HERALD_LIVE_COOKIE="better-auth.session_token=…" \
///   swift test --filter LiveEventSocketTests
/// ```
///
/// The cookie is how a test authenticates without an OAuth dance: the server
/// accepts a browser session on `/api/v1/events` whenever no `Authorization`
/// header is present, and `URLSessionConfiguration.httpAdditionalHeaders`
/// carries `Cookie` (it is not one of URLSession's reserved headers). Herald
/// itself always uses the bearer path.
@Suite(
    "Live event socket",
    .enabled(
        if: ProcessInfo.processInfo.environment["HERALD_LIVE_ORIGIN"] != nil,
        "set HERALD_LIVE_ORIGIN (and HERALD_LIVE_COOKIE) to run against a real server"
    )
)
struct LiveEventSocketTests {
    private static var origin: URL {
        URL(string: ProcessInfo.processInfo.environment["HERALD_LIVE_ORIGIN"] ?? "http://localhost:8787")!
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if let cookie = ProcessInfo.processInfo.environment["HERALD_LIVE_COOKIE"] {
            configuration.httpAdditionalHeaders = [
                "Cookie": cookie,
                // The server refuses a SESSION-authenticated upgrade whose Origin
                // is not its own (`validateSessionOrigin`); the bearer path Herald
                // uses skips that check entirely.
                "Origin": Self.origin.absoluteString
            ]
        }
        return configuration
    }

    /// The upgrade itself: a real 101, through Herald's own channel type.
    @Test("The channel opens a live socket and receives the server's frames")
    func opensAndReceives() async throws {
        let channels = URLSessionMailEventChannels(origin: Self.origin, configuration: Self.configuration)
        let channel = try await channels.open(token: ProcessInfo.processInfo.environment["HERALD_LIVE_TOKEN"] ?? "")

        // Any mutation on the server produces a frame; the harness that drives
        // this test makes one from outside while the socket is up.
        let frame = try await channel.receive()
        #expect(MailEventSocket.topic(inFrame: frame) != nil, "received: \(frame)")
        channel.close()
    }

    /// A bad credential has to arrive as ``MailEventChannelError/unauthorized``
    /// and not as an opaque transport failure, or the socket's one-refresh rule
    /// never fires.
    @Test("A rejected upgrade surfaces as .unauthorized")
    func rejectedUpgrade() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        let channels = URLSessionMailEventChannels(origin: Self.origin, configuration: configuration)
        await #expect(throws: MailEventChannelError.unauthorized) {
            _ = try await channels.open(token: "not-a-real-token")
        }
    }
}
