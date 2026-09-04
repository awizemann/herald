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
}
