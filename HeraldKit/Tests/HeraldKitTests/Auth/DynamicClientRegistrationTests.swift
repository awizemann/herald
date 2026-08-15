import Foundation
import Testing
@testable import HeraldKit

@Suite struct DynamicClientRegistrationTests {
    /// Fails if any part of the public-client metadata is wrong: a missing
    /// `token_endpoint_auth_method: none` makes the server expect a secret Herald
    /// cannot keep, a missing `refresh_token` grant kills silent renewal, and a
    /// missing `resources` entry means the server refuses to mint `/api/v1` tokens.
    @Test("registration posts public-client metadata including resources and the full scope string")
    func registrationBody() async throws {
        let server = AuthFixtures.fullServer()
        let clientID = try await DynamicClientRegistration(session: server.makeSession())
            .register(at: AuthFixtures.metadata.registrationEndpoint!, resource: AuthFixtures.resource)

        #expect(clientID == "cid_registered")

        let recorded = try #require(server.requests(path: AuthFixtures.registerPath).first)
        #expect(recorded.method == "POST")
        #expect(recorded.headers["Content-Type"] == "application/json")

        let body = try #require(
            try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any]
        )
        #expect(body["client_name"] as? String == "Herald")
        #expect(body["redirect_uris"] as? [String] == ["herald://oauth/callback"])
        #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(body["response_types"] as? [String] == ["code"])
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["scope"] as? String == "mail:read mail:write mail:send offline_access")
        #expect(body["resources"] as? [String] == [AuthFixtures.resource])
        #expect(body["client_secret"] == nil)
    }

    /// The server answers 201. Fails on an implementation that only accepts 200.
    @Test("a 201 Created response is accepted")
    func acceptsCreated() async throws {
        let server = FakeServer()
        server.route("POST", AuthFixtures.registerPath, .json(201, #"{"client_id":"cid_201"}"#))

        let clientID = try await DynamicClientRegistration(session: server.makeSession())
            .register(at: AuthFixtures.metadata.registrationEndpoint!, resource: AuthFixtures.resource)
        #expect(clientID == "cid_201")
    }

    /// Fails if a rejected registration surfaces as a decode crash or a success with
    /// an empty client id.
    @Test("a rejected registration throws a typed error")
    func rejectedRegistrationIsTyped() async {
        let server = FakeServer()
        server.route(
            "POST", AuthFixtures.registerPath,
            .json(400, #"{"error":"invalid_redirect_uri","error_description":"Not allowed"}"#)
        )

        await #expect(throws: OAuthError.server(error: "invalid_redirect_uri", description: "Not allowed")) {
            _ = try await DynamicClientRegistration(session: server.makeSession())
                .register(at: AuthFixtures.metadata.registrationEndpoint!, resource: AuthFixtures.resource)
        }
    }

    /// Fails if a 2xx body without `client_id` is force-unwrapped.
    @Test("a 2xx response without client_id throws .registrationFailed")
    func missingClientIDIsTyped() async {
        let server = FakeServer()
        server.route("POST", AuthFixtures.registerPath, .json(201, #"{"scope":"mail:read"}"#))

        await #expect(throws: OAuthError.registrationFailed(status: 201)) {
            _ = try await DynamicClientRegistration(session: server.makeSession())
                .register(at: AuthFixtures.metadata.registrationEndpoint!, resource: AuthFixtures.resource)
        }
    }
}
