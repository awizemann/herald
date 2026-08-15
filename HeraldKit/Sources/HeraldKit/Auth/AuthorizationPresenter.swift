import AppKit
import AuthenticationServices
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.herald", category: "oauth")

/// Shows the authorization URL to the user and hands back the redirect it lands on.
///
/// `nonisolated` so ``AuthCoordinator`` can pass it into value types and tests can
/// substitute a fake with no UI at all.
public nonisolated protocol AuthorizationPresenter: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

/// `ASWebAuthenticationSession`-backed presenter.
///
/// A `nonisolated struct` whose one method hops to ``WebAuthenticationRunner`` on the
/// main actor: `ASWebAuthenticationSession` and `NSWindow` are main-actor-only and
/// not `Sendable`, so they are created, started and released without ever crossing
/// an isolation boundary.
public nonisolated struct WebAuthenticationPresenter: AuthorizationPresenter {
    /// Left `false` on purpose. An ephemeral session would force a fresh login for
    /// every account add and, worse, would not see the HQBase browser session the
    /// user already has — the consent screen at `/oauth/consent` is a normal
    /// cookie-authenticated page. The cost is that signing out of Herald does not
    /// clear the shared web session; ``AuthCoordinator/signOut(_:)`` therefore only
    /// promises to drop Herald's tokens.
    public let prefersEphemeralWebBrowserSession: Bool

    public init(prefersEphemeralWebBrowserSession: Bool = false) {
        self.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
    }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await WebAuthenticationRunner.authorize(
            url: url,
            callbackScheme: callbackScheme,
            prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
        )
    }
}

/// Main-actor home for the non-Sendable AuthenticationServices objects.
enum WebAuthenticationRunner {
    /// Sessions are kept alive here for their lifetime: `ASWebAuthenticationSession`
    /// is not retained by the system, and `presentationContextProvider` is weak.
    private static var live: [UUID: LiveSession] = [:]

    private final class LiveSession {
        let anchorProvider = KeyWindowAnchorProvider()
        var session: ASWebAuthenticationSession?
    }

    static func authorize(
        url: URL,
        callbackScheme: String,
        prefersEphemeralWebBrowserSession: Bool
    ) async throws -> URL {
        let token = UUID()
        let holder = LiveSession()
        live[token] = holder

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                MainActor.assumeIsolated { live[token] = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: Self.mapped(error))
                } else {
                    continuation.resume(throwing: OAuthError.missingAuthorizationCode)
                }
            }
            session.presentationContextProvider = holder.anchorProvider
            session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
            holder.session = session

            guard session.start() else {
                live[token] = nil
                logger.error("ASWebAuthenticationSession refused to start")
                continuation.resume(throwing: OAuthError.webAuthenticationFailed("Herald could not open the sign-in window."))
                return
            }
        }
    }

    private static func mapped(_ error: any Error) -> OAuthError {
        if (error as NSError).domain == ASWebAuthenticationSessionErrorDomain,
           (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            logger.warning("sign-in cancelled by the user")
            return .userCancelled
        }
        logger.error("web authentication failed: \(error.localizedDescription, privacy: .public)")
        return .webAuthenticationFailed(error.localizedDescription)
    }
}

/// Anchors the sheet on the key window, falling back to any window (and finally a
/// detached one) so a menu-bar-only launch still presents.
final class KeyWindowAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
        }
    }
}
