import CryptoKit
import Foundation
import Testing
@testable import HeraldKit

@Suite struct OAuthSessionTests {
    private func session(_ server: FakeServer) -> OAuthSession {
        OAuthSession(
            configuration: AuthFixtures.configuration,
            clientID: "cid_1",
            session: server.makeSession()
        )
    }

    // MARK: Authorize URL

    /// Recomputes the challenge from the verifier the request actually carries.
    /// Fails if the challenge is derived from anything but this verifier, if the
    /// method is `plain`, or if `resource` is dropped — without `resource` every
    /// Mail API call answers 401 INVALID_OAUTH_TOKEN.
    @Test("authorize URL carries resource and an S256 challenge derived from its own verifier")
    func authorizeURLIsCorrect() {
        let request = session(FakeServer()).makeAuthorizationRequest()
        let query = AuthFixtures.query(request.url)

        #expect(request.url.path == AuthFixtures.authorizePath)
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "cid_1")
        #expect(query["redirect_uri"] == "herald://oauth/callback")
        #expect(query["state"] == request.state)
        #expect(query["resource"] == AuthFixtures.resource)
        #expect(query["scope"] == "mail:read mail:write mail:send offline_access")

        #expect(query["code_challenge_method"] == "S256")
        let recomputed = Data(SHA256.hash(data: Data(request.pkce.verifier.utf8))).base64URLEncodedString()
        #expect(query["code_challenge"] == recomputed)
        #expect(query["code_challenge"] != request.pkce.verifier, "challenge must not be the plain verifier")
    }

    /// Fails if two sign-ins reuse one state/verifier (a replayable authorization).
    @Test("each authorization request gets a fresh state and verifier")
    func requestsAreUnique() {
        let oauth = session(FakeServer())
        let first = oauth.makeAuthorizationRequest()
        let second = oauth.makeAuthorizationRequest()
        #expect(first.state != second.state)
        #expect(first.pkce.verifier != second.pkce.verifier)
    }

    // MARK: Callback

    /// The security property: a callback whose state does not match is rejected
    /// BEFORE the token endpoint is touched. Fails if state is unchecked, checked
    /// after the exchange, or checked only when present.
    @Test("a state mismatch throws and never reaches the token endpoint")
    func stateMismatchNeverExchanges() async {
        let server = AuthFixtures.fullServer()
        let oauth = session(server)
        let request = oauth.makeAuthorizationRequest()
        let forged = URL(string: "herald://oauth/callback?code=stolen&state=not-the-right-state")!

        #expect(throws: OAuthError.stateMismatch) {
            _ = try oauth.authorizationCode(from: forged, for: request)
        }
        // Belt and braces: nothing was sent even after the throw.
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)

        // A callback with no state at all is equally invalid.
        #expect(throws: OAuthError.stateMismatch) {
            _ = try oauth.authorizationCode(from: URL(string: "herald://oauth/callback?code=x")!, for: request)
        }
        #expect(server.requests(path: AuthFixtures.tokenPath).isEmpty)
    }

    /// Fails if a denial callback is reported as "missing code" instead of the
    /// server's actual reason.
    @Test("an error callback surfaces the server's error code")
    func errorCallbackIsTyped() {
        let oauth = session(FakeServer())
        let request = oauth.makeAuthorizationRequest()
        let denied = URL(string: "herald://oauth/callback?error=access_denied&error_description=Nope&state=\(request.state)")!

        #expect(throws: OAuthError.server(error: "access_denied", description: "Nope")) {
            _ = try oauth.authorizationCode(from: denied, for: request)
        }
    }

    // MARK: Token endpoint

    /// Fails if `code_verifier` is omitted (PKCE defeated), if `resource` is omitted
    /// (token minted for the wrong audience), or if a `client_secret` is sent —
    /// Herald registers as a public client with `token_endpoint_auth_method: none`.
    @Test("code exchange posts a form with code_verifier, resource and client_id and no client_secret")
    func exchangeSendsPKCEAndResource() async throws {
        let server = AuthFixtures.fullServer()
        let oauth = session(server)
        let request = oauth.makeAuthorizationRequest()

        let tokens = try await oauth.exchange(code: "auth_code_1", pkce: request.pkce)

        let recorded = try #require(server.requests(path: AuthFixtures.tokenPath).first)
        #expect(recorded.method == "POST")
        #expect(recorded.headers["Content-Type"] == "application/x-www-form-urlencoded")

        let fields = AuthFixtures.form(recorded.bodyText)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "auth_code_1")
        #expect(fields["code_verifier"] == request.pkce.verifier)
        #expect(fields["client_id"] == "cid_1")
        #expect(fields["redirect_uri"] == "herald://oauth/callback")
        #expect(fields["resource"] == AuthFixtures.resource)
        #expect(fields["client_secret"] == nil)

        #expect(tokens.accessToken == "hqb_access_1")
        #expect(tokens.refreshToken == "hqb_refresh_1")
        #expect(tokens.scopes.contains("offline_access"))
        // expires_in must become an absolute date roughly an hour out.
        let expiry = try #require(tokens.expiresAt)
        #expect(expiry.timeIntervalSinceNow > 3500 && expiry.timeIntervalSinceNow <= 3600)
    }

    /// Fails if refresh reuses the authorization-code grant type, or drops the
    /// audience binding (which yields a token the Mail API rejects).
    @Test("refresh posts grant_type=refresh_token with the refresh token, client_id and resource")
    func refreshSendsRefreshGrant() async throws {
        let server = AuthFixtures.fullServer()
        let tokens = try await session(server).refresh(refreshToken: "hqb_refresh_1")

        let fields = AuthFixtures.form(try #require(server.requests(path: AuthFixtures.tokenPath).first).bodyText)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "hqb_refresh_1")
        #expect(fields["client_id"] == "cid_1")
        #expect(fields["resource"] == AuthFixtures.resource)
        #expect(fields["code_verifier"] == nil)
        #expect(tokens.accessToken == "hqb_access_1")
    }

    /// Fails if the OAuth error envelope is ignored and a generic HTTP failure is
    /// reported — ``AccountTokenProvider`` keys re-auth off `invalid_grant`.
    @Test("an OAuth error response is parsed into .server(error:description:)")
    func oauthErrorEnvelopeIsParsed() async {
        let server = FakeServer()
        server.route(
            "POST", AuthFixtures.tokenPath,
            .json(400, #"{"error":"invalid_grant","error_description":"Refresh token expired"}"#)
        )

        await #expect(throws: OAuthError.server(error: "invalid_grant", description: "Refresh token expired")) {
            _ = try await session(server).refresh(refreshToken: "dead")
        }
    }

    /// Fails if a 2xx body missing `access_token` is force-unwrapped or returns an
    /// empty token that would then 401 on every call.
    @Test("a 2xx token response without access_token throws .malformedTokenResponse")
    func malformedTokenResponse() async {
        let server = FakeServer()
        server.route("POST", AuthFixtures.tokenPath, .json(200, #"{"token_type":"Bearer"}"#))

        await #expect(throws: OAuthError.malformedTokenResponse) {
            _ = try await session(server).refresh(refreshToken: "r")
        }
    }

    /// `+` is a legal base64url-adjacent character in some server-issued values and
    /// means "space" to a form decoder. Fails if encoding is left to URLComponents.
    @Test("form encoding percent-escapes + and & rather than letting them decode as separators")
    func formEncodingEscapesReservedCharacters() {
        let encoded = OAuthHTTP.formEncode([("code", "a+b&c=d"), ("resource", AuthFixtures.resource)])
        #expect(encoded.contains("code=a%2Bb%26c%3Dd"))
        #expect(AuthFixtures.form(encoded)["code"] == "a+b&c=d")
        #expect(AuthFixtures.form(encoded)["resource"] == AuthFixtures.resource)
    }
}
