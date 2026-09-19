import Foundation
import Testing
@testable import HeraldKit

/// Hermetic (no network) coverage for the two security refusals in
/// `URLSessionMailEventChannels`: a plaintext origin must never be upgraded to
/// `ws://`, and an empty token must never open a headerless — silently
/// cookie-session-downgraded — socket.
struct URLSessionMailEventChannelTests {
    // MARK: - eventsURL refuses http/ws origins

    @Test("https origin is rewritten to wss")
    func httpsBecomesWSS() {
        let url = URLSessionMailEventChannels.eventsURL(origin: URL(string: "https://mail.example.com")!)
        #expect(url?.absoluteString == "wss://mail.example.com/api/v1/events")
    }

    @Test("wss origin stays wss")
    func wssStaysWSS() {
        let url = URLSessionMailEventChannels.eventsURL(origin: URL(string: "wss://mail.example.com")!)
        #expect(url?.absoluteString == "wss://mail.example.com/api/v1/events")
    }

    @Test("http origin is refused, not downgraded to ws")
    func httpIsRefused() {
        let url = URLSessionMailEventChannels.eventsURL(origin: URL(string: "http://mail.example.com")!)
        #expect(url == nil)
    }

    @Test("ws origin is refused")
    func wsIsRefused() {
        let url = URLSessionMailEventChannels.eventsURL(origin: URL(string: "ws://mail.example.com")!)
        #expect(url == nil)
    }

    @Test("an account path prefix survives the https rewrite")
    func pathPrefixSurvives() {
        let url = URLSessionMailEventChannels.eventsURL(origin: URL(string: "https://mail.example.com/tenant/")!)
        #expect(url?.absoluteString == "wss://mail.example.com/tenant/api/v1/events")
    }

    // MARK: - open(token:) throws on an empty token

    @Test("an empty token throws rather than opening a headerless socket")
    func emptyTokenThrows() async throws {
        let channels = URLSessionMailEventChannels(
            origin: URL(string: "https://mail.example.com")!,
            configuration: .ephemeral
        )
        await #expect(throws: MailEventChannelError.unauthorized) {
            _ = try await channels.open(token: "")
        }
    }

    @Test("a plaintext origin is refused before a token is even considered")
    func plaintextOriginRefusedEvenWithToken() async throws {
        let channels = URLSessionMailEventChannels(
            origin: URL(string: "http://mail.example.com")!,
            configuration: .ephemeral
        )
        await #expect(throws: MailEventChannelError.self) {
            _ = try await channels.open(token: "a-real-token")
        }
    }

    // MARK: - The delegate actually reaches the channel

    /// `WebSocketChannel`'s `URLSessionWebSocketDelegate` callbacks are what
    /// resume the continuation `open()` is parked on, and they are otherwise only
    /// covered by the live-server suite, which is skipped by default.
    ///
    /// A refused connection drives `didCompleteWithError` — a real callback, on
    /// the session's own background queue — all the way back into the channel.
    /// Fails (by hanging until the harness gives up, rather than by throwing) if
    /// the delegate is not wired to the channel at all: nothing would ever resume
    /// `open()`. That is exactly what a mis-attached delegate proxy looks like,
    /// and port 9 on loopback refuses instantly, so this stays hermetic and fast.
    @Test("a refused connection resumes open() through the delegate")
    func refusedConnectionResumesOpenThroughTheDelegate() async throws {
        let channels = URLSessionMailEventChannels(
            origin: URL(string: "https://127.0.0.1:9")!,
            configuration: .ephemeral
        )
        await #expect(throws: MailEventChannelError.self) {
            _ = try await channels.open(token: "a-real-token")
        }
    }

    /// The same path, one level down: built exactly as production builds it, so a
    /// delegate that is attached but whose callbacks do not forward is caught too.
    /// Fails if `close()` on the failure path stops unblocking a pending `open()`.
    @Test("a channel whose handshake is refused reports why, and closes cleanly")
    func refusedChannelReportsAndCloses() async throws {
        var request = URLRequest(url: URL(string: "wss://127.0.0.1:9/api/v1/events")!)
        request.setValue("Bearer a-real-token", forHTTPHeaderField: "Authorization")
        let channel = WebSocketChannel(request: request, configuration: .ephemeral)

        await #expect(throws: MailEventChannelError.self) { try await channel.open() }
        // Idempotent, and must not trap on a channel that never opened.
        channel.close()
        channel.close()
    }
}
