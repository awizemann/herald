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

    /// REAL-SERVER 2026-08-17 (Herald #1 + the owner's own account): HQBase's
    /// protected-resource metadata advertises `scopes_supported` WITHOUT
    /// `offline_access` (it is not an API permission), and Herald requested exactly
    /// the advertised set — so no refresh token was ever issued and every sign-in
    /// died with its first access token (~1 h). The fake now mirrors the real
    /// metadata; this fails if `offline_access` is not added on top of it, or if
    /// scopes are duplicated when a server does advertise it.
    @Test("offline_access is always requested even when the resource does not advertise it")
    func offlineAccessIsAlwaysRequested() async throws {
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, AuthFixtures.serverMetadataJSON))

        let configuration = try await OAuthDiscovery(session: server.makeSession())
            .configuration(for: AuthFixtures.origin)

        #expect(configuration.scopes == ["mail:read", "mail:write", "mail:send", "offline_access"])
        #expect(OAuthDiscovery.requestedScopes(advertised: ["mail:read", "offline_access"]) == ["mail:read", "offline_access"])
        #expect(OAuthDiscovery.requestedScopes(advertised: []) == OAuthDiscovery.defaultScopes)
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

    /// Discovery runs BEFORE anything about the origin is trusted, so a
    /// `.well-known` document is attacker-influenced input. One naming someone
    /// else's authorization endpoint would send the user's credentials — and the
    /// minted token — to that host. Fails if off-origin endpoints are accepted.
    @Test("metadata pointing off-origin is rejected as .discoveryFailed(.untrustedEndpoints)")
    func offOriginEndpointsAreRejected() async throws {
        let hostile = """
        {"issuer":"https://mail.test.invalid/api/auth",
         "authorization_endpoint":"https://evil.example.com/api/auth/oauth2/authorize",
         "token_endpoint":"https://mail.test.invalid\(AuthFixtures.tokenPath)"}
        """
        let server = FakeServer()
        server.route("GET", AuthFixtures.protectedResourcePath, .json(200, AuthFixtures.protectedResourceJSON))
        server.route("GET", AuthFixtures.suffixedMetadataPath, .json(200, hostile))
        server.route("GET", AuthFixtures.bareMetadataPath, .json(200, hostile))

        do {
            _ = try await OAuthDiscovery(session: server.makeSession())
                .configuration(for: AuthFixtures.origin)
            Issue.record("expected discovery to reject the off-origin document")
        } catch let error as OAuthError {
            guard case .discoveryFailed(_, let reason) = error else {
                Issue.record("expected .discoveryFailed, got \(error)")
                return
            }
            #expect(reason == .untrustedEndpoints)
        }
    }

    /// The unit form, so each endpoint's rule is pinned individually rather than
    /// only through the one document above.
    @Test("every contacted endpoint must be https on the origin's own host")
    func endpointTrustRules() {
        let origin = AuthFixtures.origin
        func metadata(
            issuer: String = "https://mail.test.invalid/api/auth",
            authorization: String = "https://mail.test.invalid/a",
            token: String = "https://mail.test.invalid/t",
            registration: String? = "https://mail.test.invalid/r",
            revocation: String? = nil
        ) -> OAuthServerMetadata {
            OAuthServerMetadata(
                issuer: issuer,
                authorizationEndpoint: URL(string: authorization)!,
                tokenEndpoint: URL(string: token)!,
                registrationEndpoint: registration.flatMap(URL.init(string:)),
                revocationEndpoint: revocation.flatMap(URL.init(string:))
            )
        }
        #expect(OAuthDiscovery.endpointsAreTrusted(metadata(), for: origin))
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(issuer: "https://evil.example.com/api/auth"), for: origin))
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(authorization: "https://evil.example.com/a"), for: origin))
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(token: "https://evil.example.com/t"), for: origin))
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(registration: "https://evil.example.com/r"), for: origin))
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(revocation: "https://evil.example.com/x"), for: origin))
        // Plain http on the right host is still a downgrade.
        #expect(!OAuthDiscovery.endpointsAreTrusted(metadata(token: "http://mail.test.invalid/t"), for: origin))
        // An endpoint the server does not publish is simply never contacted.
        #expect(OAuthDiscovery.endpointsAreTrusted(metadata(registration: nil), for: origin))
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
