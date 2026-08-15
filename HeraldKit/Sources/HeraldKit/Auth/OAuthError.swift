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
        }
    }
}
