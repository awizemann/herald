import Foundation
import Testing
@testable import HeraldKit

/// Covers the auth/error behaviour every later phase depends on: the bearer
/// header, the single silent refresh, and the mapping of server failures onto
/// `MailAPIError` (never a generated type).
@Suite struct AuthAndErrorTests {
    private static let invalidTokenChallenge = #"Bearer resource_metadata="https://mail.test.invalid/.well-known/oauth-protected-resource/api/v1", error="invalid_token""#
    private static let insufficientScopeChallenge = #"Bearer scope="mail:send", error="insufficient_scope""#

    private func makeClient(_ server: FakeServer, tokens: FakeTokenProvider) -> HQBaseAPIClient {
        HQBaseAPIClient(origin: FakeServer.origin, tokens: tokens, session: server.makeSession())
    }

    @Test("Every request carries the bearer token")
    func sendsAuthorizationHeader() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/mailboxes", .json(200, "[]"))
        let tokens = FakeTokenProvider(initial: "token-1")

        _ = try await makeClient(server, tokens: tokens).listMailboxes()

        let request = try #require(server.requests.first)
        // Fails if the middleware is dropped from the client or the header renamed.
        #expect(request.authorization == "Bearer token-1")
    }

    @Test("A 401 invalid_token refreshes exactly once and retries with the NEW token")
    func refreshesOnceAndRetries() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/mailboxes",
            .error(401, code: "INVALID_OAUTH_TOKEN", message: "expired", headers: ["WWW-Authenticate": Self.invalidTokenChallenge]),
            .json(200, Fixtures.mailboxesJSON)
        )
        let tokens = FakeTokenProvider(initial: "stale", refreshedTokens: ["fresh"])

        let mailboxes = try await makeClient(server, tokens: tokens).listMailboxes()

        #expect(mailboxes.count == 2)
        let attempts = server.requests(path: "/api/v1/mailboxes")
        // Fails if we never retry (1 attempt), loop (>2), or retry with the stale token.
        #expect(attempts.count == 2)
        #expect(attempts.map(\.authorization) == ["Bearer stale", "Bearer fresh"])
        #expect(await tokens.refreshCallCount == 1)
    }

    /// Issue #1 (bermanto): with no refresh token, the provider's
    /// `OAuthError.missingRefreshToken` was flattened into `.transport(...)`, so
    /// the app showed "Sync problem … Retry" and Retry could never succeed. Fails
    /// if that error (or `.reauthenticationRequired`) surfaces as anything but
    /// `.unauthorized`, the case the UI routes to the re-authenticate banner.
    @Test("A refresh that cannot happen surfaces as .unauthorized, not a transport error")
    func missingRefreshTokenIsUnauthorized() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/mailboxes",
            .error(401, code: "INVALID_OAUTH_TOKEN", message: "expired", headers: ["WWW-Authenticate": Self.invalidTokenChallenge])
        )
        for failure in [OAuthError.missingRefreshToken, OAuthError.reauthenticationRequired] {
            let tokens = FakeTokenProvider(initial: "stale", refreshedTokens: [])
            await tokens.setRefreshFailure(failure)
            do {
                _ = try await makeClient(server, tokens: tokens).listMailboxes()
                Issue.record("expected a throw for \(failure)")
            } catch let error as MailAPIError {
                #expect(error == .unauthorized, "got \(error) for \(failure)")
            }
        }
    }

    @Test("A second 401 after refreshing surfaces .unauthorized instead of looping")
    func secondUnauthorizedGivesUp() async throws {
        let server = FakeServer()
        server.route(
            "GET",
            "/api/v1/mailboxes",
            .error(401, code: "INVALID_OAUTH_TOKEN", message: "expired", headers: ["WWW-Authenticate": Self.invalidTokenChallenge])
        )
        let tokens = FakeTokenProvider(initial: "stale", refreshedTokens: ["also-stale"])

        await #expect(throws: MailAPIError.unauthorized) {
            _ = try await makeClient(server, tokens: tokens).listMailboxes()
        }
        #expect(server.requests(path: "/api/v1/mailboxes").count == 2)
        #expect(await tokens.refreshCallCount == 1)
    }

    @Test("403 insufficient_scope surfaces the required scope and does NOT refresh")
    func insufficientScope() async throws {
        let server = FakeServer()
        server.route(
            "POST",
            "/api/v1/send",
            .error(403, code: "INSUFFICIENT_SCOPE", message: "missing scope", headers: ["WWW-Authenticate": Self.insufficientScopeChallenge])
        )
        let tokens = FakeTokenProvider()
        let input = SendInput(from: "support@example.com", to: ["a@b.test"], subject: "Hi", text: "Hello")

        await #expect(throws: MailAPIError.insufficientScope("mail:send")) {
            _ = try await makeClient(server, tokens: tokens).send(input)
        }
        // Refreshing on a scope failure would burn a refresh token for nothing.
        #expect(await tokens.refreshCallCount == 0)
        #expect(server.requests(path: "/api/v1/send").count == 1)
    }

    @Test("A server error body maps to .server(code:message:) with the real code")
    func serverErrorBody() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .error(429, code: "RATE_LIMITED", message: "Slow down"))
        let tokens = FakeTokenProvider()

        await #expect(throws: MailAPIError.server(code: "RATE_LIMITED", message: "Slow down")) {
            _ = try await makeClient(server, tokens: tokens).listMessages(folder: .inbox)
        }
    }

    @Test("404 maps to .notFound rather than a generic server error")
    func notFound() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages/missing", .error(404, code: "NOT_FOUND", message: "no such message"))
        let tokens = FakeTokenProvider()

        await #expect(throws: MailAPIError.notFound) {
            _ = try await makeClient(server, tokens: tokens).message(id: "missing")
        }
    }

    @Test("A malformed 2xx body maps to .decoding, not a crash or a transport error")
    func decodingFailure() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/mailboxes", .json(200, #"{"not":"an array"}"#))
        let tokens = FakeTokenProvider()

        await #expect(throws: MailAPIError.decoding) {
            _ = try await makeClient(server, tokens: tokens).listMailboxes()
        }
    }

    @Test("Query filters reach the wire as folder/mailboxId/search")
    func listMessagesSendsFilters() async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/messages", .json(200, "[]"))
        let tokens = FakeTokenProvider()

        _ = try await makeClient(server, tokens: tokens)
            .listMessages(folder: .archived, mailboxID: "mbx_support", search: "invoice")

        let query = try #require(server.requests(path: "/api/v1/messages").first?.query)
        // Fails if a filter is dropped or spelled with the Swift-side name.
        #expect(query.contains("folder=archived"))
        #expect(query.contains("mailboxId=mbx_support"))
        #expect(query.contains("search=invoice"))
    }

    @Test("Conversation actions send the folder context in the body")
    func conversationActionBody() async throws {
        let server = FakeServer()
        server.route(
            "POST",
            "/api/v1/conversations/thr_09/archive",
            .json(200, #"{"affected":3,"threadId":"thr_09"}"#)
        )
        let tokens = FakeTokenProvider()

        let result = try await makeClient(server, tokens: tokens)
            .perform(.archive, onConversation: "thr_09", in: .inbox)

        #expect(result.threadID == "thr_09")
        #expect(result.affected == 3)
        let body = try #require(server.requests(path: "/api/v1/conversations/thr_09/archive").first?.compactBodyText)
        // The server rejects the request without it, so a dropped body is a real bug.
        #expect(body.contains(#""folder":"inbox""#))
    }
}
