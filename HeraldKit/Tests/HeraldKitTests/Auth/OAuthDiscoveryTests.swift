import Foundation
import Testing
@testable import HeraldKit

@Suite struct OAuthDiscoveryTests {
    /// The path-suffixed RFC 8414 URL is where HQBase actually publishes its
    /// metadata (issuer `{origin}/api/auth`). Fails if discovery only ever asks the
    /// bare `.well-known` path, or builds the suffix by appending instead of
    /// inserting it before the issuer path.
    @Test("metadata is read from the RFC 8414 path-suffixed URL derived from the issuer")
    func usesPathSuffixedMetadataURL() async throws {
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, AuthFixtures.serverMetadataJSON))
        // Deliberately NOT routed: a client that falls back to the bare path 501s.

        let configuration = try await OAuthDiscovery(session: server.makeSession())
            .configuration(for: AuthFixtures.origin)

        #expect(configuration.server.issuer == "https://mail.test.invalid/api/auth")
        #expect(configuration.server.tokenEndpoint.path == AuthFixtures.tokenPath)
        #expect(configuration.server.registrationEndpoint?.path == AuthFixtures.registerPath)
        #expect(configuration.server.deviceAuthorizationEndpoint != nil)
        #expect(server.requests(path: AuthFixtures.suffixedMetadataPath).count == 1)
    }

    /// Fails if the bare-path fallback is missing: a server that publishes only
    /// `{origin}/.well-known/oauth-authorization-server` would become unusable.
    @Test("falls back to the bare well-known path when the suffixed one is absent")
    func fallsBackToBareMetadataPath() async throws {
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .error(404, code: "not_found", message: "no"))
        server.route("GET", AuthFixtures.bareMetadataPath, .json(200, AuthFixtures.serverMetadataJSON))

        let configuration = try await OAuthDiscovery(session: server.makeSession())
            .configuration(for: AuthFixtures.origin)

        #expect(configuration.server.tokenEndpoint.path == AuthFixtures.tokenPath)
        #expect(server.requests(path: AuthFixtures.bareMetadataPath).count == 1)
    }

    /// The resource is what binds the token to `/api/v1`; a server too old to publish
    /// the RFC 9728 document must still yield the right audience. Fails if a missing
    /// protected-resource document aborts discovery.
    @Test("missing protected-resource metadata falls back to {origin}/api/v1")
    func protectedResourceFallback() async throws {
        let server = FakeServer()
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, AuthFixtures.serverMetadataJSON))

        let configuration = try await OAuthDiscovery(session: server.makeSession())
            .configuration(for: URL(string: "https://mail.test.invalid/")!)

        #expect(configuration.resource == "https://mail.test.invalid/api/v1")
        #expect(configuration.scopes == OAuthDiscovery.defaultScopes)
    }

    /// Fails if a garbage `.well-known` body escapes as a raw `DecodingError` (or
    /// crashes on a force-try/force-unwrap) instead of a typed OAuth error.
    @Test("a malformed metadata document throws .discoveryFailed(.decoding), not a DecodingError")
    func malformedMetadataIsTyped() async {
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, #"{"issuer":"x"}"#))
        server.route("GET", AuthFixtures.bareMetadataPath, .json(200, "not json at all"))

        await #expect(throws: OAuthError.self) {
            _ = try await OAuthDiscovery(session: server.makeSession())
                .configuration(for: AuthFixtures.origin)
        }

        do {
            _ = try await OAuthDiscovery(session: server.makeSession())
                .configuration(for: AuthFixtures.origin)
            Issue.record("expected discovery to fail")
        } catch let error as OAuthError {
            guard case .discoveryFailed(_, let reason) = error else {
                Issue.record("expected .discoveryFailed, got \(error)")
                return
            }
            #expect(reason == .decoding)
        } catch {
            Issue.record("expected OAuthError, got \(error)")
        }
    }

    /// Fails if an origin that serves nothing at all produces an untyped transport
    /// error or hangs instead of a typed discovery failure.
    @Test("an origin with no OAuth documents throws a typed discovery failure")
    func unreachableMetadataIsTyped() async {
        let server = FakeServer()

        do {
            _ = try await OAuthDiscovery(session: server.makeSession())
                .configuration(for: AuthFixtures.origin)
            Issue.record("expected discovery to fail")
        } catch let error as OAuthError {
            guard case .discoveryFailed(_, let reason) = error else {
                Issue.record("expected .discoveryFailed, got \(error)")
                return
            }
            #expect(reason == .status)
        } catch {
            Issue.record("expected OAuthError, got \(error)")
        }
    }

    /// Fails if the RFC 8414 insertion is written as a suffix append.
    @Test("metadataURL inserts .well-known before the issuer path")
    func metadataURLInsertion() throws {
        let issuer = URL(string: "https://mail.test.invalid/api/auth")!
        #expect(
            OAuthDiscovery.metadataURL(forIssuer: issuer)?.absoluteString
                == "https://mail.test.invalid/.well-known/oauth-authorization-server/api/auth"
        )
        // A root issuer has no path to suffix.
        #expect(OAuthDiscovery.metadataURL(forIssuer: URL(string: "https://mail.test.invalid")!) == nil)
    }
}
