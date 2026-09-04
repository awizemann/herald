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
/// itself always uses the bearer path — `URLSessionMailEventChannels.open(token:)`
/// throws on an empty token rather than omitting the header, so the
/// cookie-session path is exercised through ``CookieSessionEventChannelOpener``,
/// a test-only opener that goes straight through `WebSocketChannel`'s
/// production request-building without the bearer-token seam.
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
    ///
    /// A real `HERALD_LIVE_TOKEN` takes the production bearer path through
    /// `URLSessionMailEventChannels`; without one, this falls back to the
    /// cookie-session opener so the test still runs against a server that
    /// only has `HERALD_LIVE_COOKIE` configured.
    @Test("The channel opens a live socket and receives the server's frames")
    func opensAndReceives() async throws {
        let channel: any MailEventChannel
        if let token = ProcessInfo.processInfo.environment["HERALD_LIVE_TOKEN"], !token.isEmpty {
            let channels = URLSessionMailEventChannels(origin: Self.origin, configuration: Self.configuration)
            channel = try await channels.open(token: token)
        } else {
            let opener = CookieSessionEventChannelOpener(origin: Self.origin, configuration: Self.configuration)
            channel = try await opener.open()
        }

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

/// Opens `/api/v1/events` with no `Authorization` header at all, so the server
/// falls back to the browser session carried in `HERALD_LIVE_COOKIE`.
///
/// This is deliberately NOT how production opens a socket —
/// `URLSessionMailEventChannels.open(token:)` throws on an empty token rather
/// than send a headerless request, because a real Herald account always has a
/// token and a bug that hands it an empty one must fail loudly. Only this test
/// suite needs the cookie-session fallback, since it is the one way to reach a
/// live socket without an OAuth dance.
private nonisolated struct CookieSessionEventChannelOpener {
    let origin: URL
    let configuration: URLSessionConfiguration

    func open() async throws -> any MailEventChannel {
        guard let url = URLSessionMailEventChannels.eventsURL(origin: origin) else {
            throw MailEventChannelError.transport("the account origin is not a usable URL")
        }
        let request = URLRequest(url: url)
        let channel = WebSocketChannel(request: request, configuration: configuration)
        do {
            try await channel.open()
        } catch {
            channel.close()
            throw error
        }
        return channel
    }
}
