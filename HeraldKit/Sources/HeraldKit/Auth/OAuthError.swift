import Foundation

/// Every failure the auth layer surfaces. Never carries a token or a verifier.
public nonisolated enum OAuthError: Error, Sendable, Hashable {
    /// A `.well-known` document was missing, non-2xx, or did not parse.
    /// `reason` is a short diagnostic, never a response body.
    case discoveryFailed(url: String, reason: DiscoveryFailure)
    /// The authorization server has no `registration_endpoint`, so Herald cannot
    /// self-register and the user must be told to use a server that allows it.
    case registrationUnsupported
    /// Dynamic client registration answered non-2xx or without a `client_id`.
    case registrationFailed(status: Int)
    /// The server's `{error, error_description}` payload, verbatim.
    case server(error: String, description: String?)
    /// The callback's `state` did not match the one Herald generated — the response
    /// is discarded and the code is never redeemed.
    case stateMismatch
    /// The callback URL had neither `code` nor `error`.
    case missingAuthorizationCode
    /// Refresh failed with `invalid_grant`: the refresh token is dead, the user must
    /// sign in again. Callers turn this into a re-auth prompt, not a retry.
    case reauthenticationRequired
    /// Refresh was requested but no refresh token was ever issued
    /// (the server did not grant `offline_access`).
    case missingRefreshToken
    /// A token response was 2xx but had no `access_token`.
    case malformedTokenResponse
    /// The user closed the web authentication sheet.
    case userCancelled
    /// `ASWebAuthenticationSession` could not start or failed for another reason.
    case webAuthenticationFailed(String)
    /// No account with that id is known to the ``AccountStore``.
    case unknownAccount(String)
    /// The request never produced an HTTP response.
    case transport(MailAPIError.TransportFailure)
    /// The server refused Herald's `client_id` during a sign-in (`invalid_client`
    /// or `unauthorized_client` on the callback or the code exchange): the
    /// dynamic registration it was minted under is gone — typically the server
    /// was reinstalled or its client table reset. The stored registration for
    /// that origin has already been forgotten when this is thrown, so the NEXT
    /// sign-in registers Herald again. Not retried automatically: that would
    /// open a second browser window the user did not ask for.
    case clientRegistrationRejected

    public nonisolated enum DiscoveryFailure: String, Sendable, Hashable {
        case status
        case decoding
        case transport
        /// The metadata parsed but pointed the flow at another host (or at plain
        /// http): a `.well-known` document that sends authorization elsewhere is
        /// exactly how a token gets minted for someone else.
        case untrustedEndpoints
    }

    /// True for the one OAuth error code that means "this grant is dead, re-auth".
    public var isInvalidGrant: Bool {
        if case .server(let error, _) = self { return error == "invalid_grant" }
        return false
    }

    /// The token endpoint (or the authorization callback) says the CLIENT is the
    /// problem, not the grant: `invalid_client` (unknown or disabled `client_id`
    /// — HQBase's better-auth answers 400 `invalid_client` "missing client" for a
    /// public client it no longer has) or `unauthorized_client` (the client may
    /// no longer use this grant type). Only a new registration fixes either, so
    /// the stored `client.<origin>` must be forgotten.
    ///
    /// Deliberately the server's explicit words only. A 401 with no readable
    /// OAuth error body (`http_401`) is NOT this: HQBase always sends the JSON
    /// body, so a bare 401 is a proxy or gateway speaking, and discarding a
    /// registration on its say-so would only orphan a working client.
    public var isRejectedClient: Bool {
        guard case .server(let error, _) = self else { return false }
        return error == "invalid_client" || error == "unauthorized_client"
    }

    /// A refresh refusal that no retry of the same grant can ever turn into a
    /// token, so ``AccountTokenProvider`` treats it as a dead session (latch,
    /// announce once, stop spending) instead of surfacing it as a sync error
    /// whose Retry repeats the doomed request (audit W3).
    ///
    /// - ``isRejectedClient`` (the registration is dead).
    /// - ``isScopeRefusal``: the grant can no longer be exchanged for the scopes
    ///   or the audience (`resource`) Herald asks for — a fresh consent against a
    ///   FRESH discovery and registration can.
    ///
    /// NOT `invalid_grant`: that one has its own, stricter path (the grant is
    /// cleared from the store) — see ``isInvalidGrant``.
    ///
    /// NOT `http_401` either (P9a, superseding W3's first cut): a 401 with no
    /// readable OAuth body never reached the server's grant logic — HQBase
    /// always answers with the JSON body, so a bare 401 is a proxy or gateway
    /// speaking. Latching on it turned one gateway blip into a banner and a
    /// consent window until relaunch; it is ``isRetryable`` instead, the same
    /// rule P6 applies on the API side (a 401 is a session verdict only when the
    /// server says so).
    public var isTerminalRefreshRefusal: Bool {
        isRejectedClient || isScopeRefusal
    }

    /// `invalid_scope` / `invalid_target`: the registration and discovery the
    /// grant was minted under ask for scopes or an audience the server no longer
    /// grants. Re-consenting with the SAME cached discovery and scope-bound
    /// registration can never succeed, so both are discarded before the death
    /// is announced (see ``AccountTokenProvider``).
    public var isScopeRefusal: Bool {
        guard case .server(let error, _) = self else { return false }
        return error == "invalid_scope" || error == "invalid_target"
    }

    /// Worth exactly one more attempt: the network or the server failed us, so the
    /// grant itself is probably still good. Never true for `invalid_grant` — retrying
    /// a dead grant is the classic sign-out loop.
    public var isRetryable: Bool {
        switch self {
        case .transport:
            true
        case .server(let error, _):
            // `http_401`: a bodiless 401 from the token endpoint is a gateway, not
            // a verdict on the grant — see ``isTerminalRefreshRefusal``.
            error == "server_error" || error == "temporarily_unavailable" || error.hasPrefix("http_5")
                || error == "http_401"
        default:
            false
        }
    }

    /// Wraps a thrown error without letting an unexpected type escape as itself.
    static func wrapTransport(_ error: any Error) -> OAuthError {
        if let oauth = error as? OAuthError { return oauth }
        return .transport(MailAPIError.TransportFailure(error))
    }
}

nonisolated extension OAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .discoveryFailed(let url, _):
            "\(url) does not look like an HQBase server."
        case .registrationUnsupported:
            "This server does not allow apps to register themselves."
        case .registrationFailed:
            "Herald could not register with this server."
        case .server(let error, let description):
            description ?? error
        case .stateMismatch:
            "The sign-in response did not match this request and was discarded."
        case .missingAuthorizationCode:
            "The server did not return an authorization code."
        case .reauthenticationRequired:
            "Your session has expired. Sign in again."
        case .missingRefreshToken:
            "This account was not granted offline access. Sign in again."
        case .malformedTokenResponse:
            "The server sent a sign-in response Herald could not read."
        case .userCancelled:
            "Sign-in was cancelled."
        case .webAuthenticationFailed(let reason):
            reason
        case .unknownAccount:
            "That account is no longer signed in."
        case .transport(let failure):
            failure.localizedDescription
        case .clientRegistrationRejected:
            "This server no longer recognizes Herald. Sign in again and Herald will register with it anew."
        }
    }
}
