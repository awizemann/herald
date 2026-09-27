#if DEBUG
import Foundation
import HeraldKit
import os

/// What the fake server does to the grants that exist when it is switched.
///
/// A state applies to every grant (and, for ``invalidClient``, every client
/// registration) that exists at the moment it is set — including the seeded
/// ones when it is given at launch. A grant minted AFTERWARDS by a fresh sign-in
/// (authorization code) starts live, which is how a test exercises recovery:
/// kill the session, then sign in again. ``healthy`` revives everything.
nonisolated enum FakeHQBaseState: String, Sendable, CaseIterable {
    /// Everything works.
    case healthy
    /// HQBase 1.4.0's dead web session (the 2026-09-26 incident): every Mail API
    /// call with the grant's tokens is `401 INVALID_OAUTH_TOKEN` with
    /// `WWW-Authenticate: Bearer … error="invalid_token"`, while the refresh
    /// grant keeps answering 200 and rotating — minting tokens that are
    /// rejected the same way.
    case deadSession140
    /// The grant was revoked: resource calls 401 `invalid_token`, refresh
    /// `400 {"error":"invalid_grant"}`.
    case invalidGrant
    /// A proxy in front of the token endpoint: resource calls 401
    /// `invalid_token`, refresh answers a BARE 401 (no OAuth JSON).
    case bareTokenEndpoint401
    /// The client registration is gone: resource calls 401 `invalid_token`,
    /// refresh AND code exchange with the old client `400 {"error":"invalid_client"}`.
    /// A new registration works.
    case invalidClient
}

/// Request counters a UI test asserts on (e.g. "the message was sent once").
nonisolated struct FakeHQBaseCounters: Sendable, Equatable {
    /// Distinct messages accepted by `POST /send`, `/reply`, `/forward`. An
    /// idempotent replay (same key, same body) is NOT counted again.
    var sends = 0
    /// Every send/reply/forward request, replays and refusals included.
    var sendRequests = 0
    /// Every `POST /api/auth/oauth2/token`, whatever the grant and outcome.
    var tokenRequests = 0
    var refreshes = 0
    var codeExchanges = 0
    var registrations = 0
    var revocations = 0
    var draftCreates = 0
    var draftUpdates = 0
    var draftDeletes = 0
    /// Mail API requests answered 401.
    var unauthorized = 0
    /// `GET /events` upgrades refused (see ``FakeEventChannels``).
    var eventRefusals = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            sends: lhs.sends + rhs.sends,
            sendRequests: lhs.sendRequests + rhs.sendRequests,
            tokenRequests: lhs.tokenRequests + rhs.tokenRequests,
            refreshes: lhs.refreshes + rhs.refreshes,
            codeExchanges: lhs.codeExchanges + rhs.codeExchanges,
            registrations: lhs.registrations + rhs.registrations,
            revocations: lhs.revocations + rhs.revocations,
            draftCreates: lhs.draftCreates + rhs.draftCreates,
            draftUpdates: lhs.draftUpdates + rhs.draftUpdates,
            draftDeletes: lhs.draftDeletes + rhs.draftDeletes,
            unauthorized: lhs.unauthorized + rhs.unauthorized,
            eventRefusals: lhs.eventRefusals + rhs.eventRefusals
        )
    }
}

/// A request as the fake transport hands it over.
nonisolated struct FakeHTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

nonisolated struct FakeHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

/// One in-process HQBase: OAuth discovery, dynamic registration, the token
/// endpoint and the slice of the Mail API v1 Herald uses, shaped exactly like
/// the vendored OpenAPI spec (HeraldKit/Sources/HeraldAPI/openapi.json) so the
/// REAL generated client, `AuthenticatingMiddleware`, `AccountTokenProvider`
/// and `SyncEngine` run against it unmodified.
///
/// All state sits behind one `os_unfair_lock` and every request is answered
/// synchronously while holding it: `URLProtocol` calls in from URLSession's
/// own threads, and nothing here ever suspends.
nonisolated final class FakeHQBase: @unchecked Sendable {
    let origin: URL
    let host: String
    /// The one mailbox this server serves.
    let mailboxAddress: String
    let mailboxID: String

    private let state: OSAllocatedUnfairLock<ServerState>

    init(origin: URL, mailboxAddress: String) {
        self.origin = Account.normalize(origin)
        self.host = origin.host ?? "uitest.invalid"
        self.mailboxAddress = mailboxAddress
        self.mailboxID = "mbx_\(host.split(separator: ".").first ?? "uitest")"
        self.state = OSAllocatedUnfairLock(initialState: ServerState())
    }

    // MARK: - Control

    var mode: FakeHQBaseState { state.withLock { $0.mode } }

    var counters: FakeHQBaseCounters { state.withLock { $0.counters } }

    /// Told after every request and every control change.
    func setObserver(_ observer: (@Sendable () -> Void)?) {
        state.withLock { $0.observer = observer }
    }

    func setState(_ mode: FakeHQBaseState) {
        let observer = state.withLock { state -> (@Sendable () -> Void)? in
            state.mode = mode
            switch mode {
            case .healthy:
                for key in state.grants.keys where state.grants[key]?.condition != .revokedByClient { state.grants[key]?.condition = .live }
                for key in state.clients.keys { state.clients[key] = true }
            case .deadSession140:
                for key in state.grants.keys where state.grants[key]?.condition != .revokedByClient { state.grants[key]?.condition = .sessionDead }
            case .invalidGrant:
                for key in state.grants.keys where state.grants[key]?.condition != .revokedByClient { state.grants[key]?.condition = .revoked }
            case .bareTokenEndpoint401:
                for key in state.grants.keys where state.grants[key]?.condition != .revokedByClient { state.grants[key]?.condition = .proxy401 }
            case .invalidClient:
                for key in state.grants.keys where state.grants[key]?.condition != .revokedByClient { state.grants[key]?.condition = .revoked }
                for key in state.clients.keys { state.clients[key] = false }
            }
            return state.observer
        }
        observer?()
    }

    func resetCounters() {
        let observer = state.withLock { state -> (@Sendable () -> Void)? in
            state.counters = FakeHQBaseCounters()
            return state.observer
        }
        observer?()
    }

    /// The server's copy of every message (Inbox, Sent, …), for assertions.
    var messageSubjects: [String] { state.withLock { $0.messages.map(\.subject) } }

    var draftCount: Int { state.withLock { $0.drafts.count } }

    // MARK: - Seeding

    /// Registers `clientID` as a live client.
    func seedClient(_ clientID: String) {
        state.withLock { $0.clients[clientID] = true }
    }

    /// Mints a live grant for `clientID`, as a completed sign-in would have.
    func seedGrant(clientID: String) -> OAuthTokens {
        state.withLock { state in
            state.clients[clientID] = true
            return state.mintGrant(clientID: clientID, scope: Self.grantedScope, host: host)
        }
    }

    /// A few Inbox messages from different senders, newest first; the first two unread.
    func seedInbox(now: Date = Date()) {
        let senders: [(String, String, String, String)] = [
            ("ada@example.net", "Ada Lovelace", "Quarterly numbers", "Here are the numbers for the quarter."),
            ("grace@example.org", "Grace Hopper", "Compiler notes", "Notes from yesterday's compiler review."),
            ("alan@example.com", "Alan Turing", "Lunch on Friday?", "Are you free for lunch on Friday?"),
            ("barbara@example.net", "Barbara Liskov", "Substitution", "A short note about substitutability."),
            ("edsger@example.org", "Edsger Dijkstra", "Shortest paths", "The graph you sent has a shorter path."),
        ]
        state.withLock { state in
            for (index, sender) in senders.enumerated() {
                let received = now.addingTimeInterval(TimeInterval(-3600 * (index + 1)))
                let id = "msg_\(host.split(separator: ".").first ?? "x")_\(index + 1)"
                state.insert(MessageRecord(
                    id: id,
                    threadId: "thr_\(id)",
                    mailboxId: mailboxID,
                    direction: "inbound",
                    folder: "inbox",
                    fromAddress: sender.0,
                    fromName: sender.1,
                    to: [mailboxAddress],
                    subject: sender.2,
                    text: sender.3,
                    receivedAt: received,
                    sentAt: nil,
                    readAt: index < 2 ? nil : received,
                    starredAt: nil,
                    createdAt: received
                ))
            }
        }
    }

    /// The scope HQBase echoes on a token response for Herald's request.
    static let grantedScope = "mail:read mail:write mail:send offline_access"

    // MARK: - Authorization (the browser half, played by the scripted presenter)

    /// What the consent page does when the user approves: validate the request
    /// and redirect to the callback with a fresh code and the request's state.
    /// An unknown or disabled client gets HQBase's own error page — no redirect
    /// — which the user can only close: reported as `OAuthError.userCancelled`.
    func approveAuthorization(_ url: URL) throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let clientID = value("client_id"), let redirect = value("redirect_uri"),
              let challenge = value("code_challenge"), value("code_challenge_method") == "S256",
              let state = value("state")
        else {
            throw OAuthError.webAuthenticationFailed("UI test: the authorize request was malformed.")
        }
        let resourceParam = value("resource") ?? ""
        let scopeParam = value("scope") ?? Self.grantedScope
        let code = try self.state.withLock { server -> String in
            guard server.clients[clientID] == true else {
                // HQBase shows its own error page and never redirects; the
                // only way out is the user closing the sheet.
                throw OAuthError.userCancelled
            }
            server.serial += 1
            let code = "uitest-code-\(server.serial)"
            server.codes[code] = CodeRecord(
                clientID: clientID,
                redirectURI: redirect,
                challenge: challenge,
                resource: resourceParam,
                scope: scopeParam
            )
            return code
        }
        var callback = URLComponents(string: redirect)
        callback?.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
        guard let callbackURL = callback?.url else {
            throw OAuthError.webAuthenticationFailed("UI test: bad redirect URI.")
        }
        return callbackURL
    }

    // MARK: - Events

    /// The wake socket's upgrade is always refused with HQBase's
    /// "Continue with HTTP synchronization" answer, so polling carries the app.
    func refuseEventsUpgrade() {
        let observer = state.withLock { state -> (@Sendable () -> Void)? in
            state.counters.eventRefusals += 1
            return state.observer
        }
        observer?()
    }

    // MARK: - HTTP

    func respond(to request: FakeHTTPRequest) -> FakeHTTPResponse {
        let (response, observer) = state.withLock { state in
            (route(request, state: &state), state.observer)
        }
        observer?()
        return response
    }

    private var resource: String { Account.resource(for: origin) }

    private func route(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        let path = request.path
        switch (request.method, path) {
        case ("GET", "/.well-known/oauth-protected-resource/api/v1"):
            return .json(200, [
                "resource": resource,
                "authorization_servers": ["\(origin.absoluteString)/api/auth"],
                // 1.4.0's advertised set: the API permissions only (offline_access
                // is deliberately absent; Herald always adds it).
                "scopes_supported": ["mail:read", "mail:write", "mail:send"],
                "bearer_methods_supported": ["header"],
            ])
        case ("GET", "/.well-known/oauth-authorization-server/api/auth"),
             ("GET", "/.well-known/oauth-authorization-server"):
            let base = "\(origin.absoluteString)/api/auth"
            return .json(200, [
                "issuer": base,
                "authorization_endpoint": "\(base)/oauth2/authorize",
                "token_endpoint": "\(base)/oauth2/token",
                "registration_endpoint": "\(base)/oauth2/register",
                "revocation_endpoint": "\(base)/oauth2/revoke",
                "code_challenge_methods_supported": ["S256"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
            ])
        case ("POST", "/api/auth/oauth2/register"):
            return register(request, state: &state)
        case ("POST", "/api/auth/oauth2/token"):
            return token(request, state: &state)
        case ("POST", "/api/auth/oauth2/revoke"):
            state.counters.revocations += 1
            let form = Self.form(request.body)
            if let token = form["token"] {
                if let id = state.refreshIndex[token] ?? state.accessIndex[token] {
                    state.grants[id]?.condition = .revokedByClient
                }
            }
            return FakeHTTPResponse(status: 200)
        default:
            break
        }
        guard path.hasPrefix("/api/v1/") else {
            return .error(404, code: "NOT_FOUND", message: "No route for \(request.method) \(path)")
        }
        // Counted before authentication, so a send refused with 401 is still
        // a send REQUEST (a dead session's Send shows up here).
        if request.method == "POST", ["/api/v1/send", "/api/v1/reply", "/api/v1/forward"].contains(path) {
            state.counters.sendRequests += 1
        }
        if let refusal = authenticate(request, state: &state) { return refusal }
        return mailAPI(request, state: &state)
    }

    // MARK: OAuth

    private func register(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        state.counters.registrations += 1
        guard let body = Self.jsonObject(request.body) else {
            return .json(400, ["error": "invalid_client_metadata", "error_description": "body is not JSON"])
        }
        guard body["application_type"] as? String == "native" else {
            return .json(400, [
                "error": "invalid_redirect_uri",
                "error_description": "web clients require https redirect URIs on non-loopback hosts",
            ])
        }
        guard let redirects = body["redirect_uris"] as? [String], !redirects.isEmpty else {
            return .json(400, ["error": "invalid_redirect_uri", "error_description": "redirect_uris required"])
        }
        state.serial += 1
        let clientID = "uitest-\(host.split(separator: ".").first ?? "x")-client-\(state.serial)"
        state.clients[clientID] = true
        return .json(201, [
            "client_id": clientID,
            "scope": body["scope"] as? String ?? Self.grantedScope,
            "token_endpoint_auth_method": "none",
            "redirect_uris": redirects,
        ])
    }

    private func token(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        state.counters.tokenRequests += 1
        let form = Self.form(request.body)
        switch form["grant_type"] {
        case "authorization_code":
            state.counters.codeExchanges += 1
            guard let clientID = form["client_id"], state.clients[clientID] == true else {
                return Self.oauthError(400, "invalid_client", "missing client")
            }
            guard let code = form["code"], let record = state.codes.removeValue(forKey: code),
                  record.clientID == clientID,
                  record.redirectURI == form["redirect_uri"],
                  let verifier = form["code_verifier"],
                  PKCE.isValid(verifier), PKCE.challenge(for: verifier) == record.challenge
            else {
                return Self.oauthError(400, "invalid_grant", "invalid authorization code")
            }
            guard form["resource"] == resource, record.resource == resource else {
                return Self.oauthError(400, "invalid_target", "resource must be \(resource)")
            }
            let tokens = state.mintGrant(clientID: clientID, scope: record.scope, host: host)
            return Self.tokenResponse(tokens)
        case "refresh_token":
            state.counters.refreshes += 1
            let grantID = form["refresh_token"].flatMap { state.refreshIndex[$0] }
            if let grantID, state.grants[grantID]?.condition == .proxy401 {
                return FakeHTTPResponse(
                    status: 401,
                    headers: ["Content-Type": "text/html"],
                    body: Data("<html><body>401 Unauthorized</body></html>".utf8)
                )
            }
            // The client is validated before the grant, as better-auth does.
            guard let clientID = form["client_id"], state.clients[clientID] == true else {
                return Self.oauthError(400, "invalid_client", "missing client")
            }
            guard let grantID, var grant = state.grants[grantID], grant.clientID == clientID,
                  grant.condition != .revoked, grant.condition != .revokedByClient
            else {
                return Self.oauthError(400, "invalid_grant", "invalid refresh token")
            }
            // Rotation: the old refresh token stops working, and a dead 1.4.0
            // session rotates just as happily as a live one.
            if let old = form["refresh_token"] { state.refreshIndex[old] = nil }
            let tokens = state.mintTokens(scope: grant.scope, host: host)
            grant.refreshToken = tokens.refreshToken ?? ""
            state.grants[grantID] = grant
            state.refreshIndex[grant.refreshToken] = grantID
            state.accessIndex[tokens.accessToken] = grantID
            return Self.tokenResponse(tokens)
        default:
            return Self.oauthError(400, "unsupported_grant_type", nil)
        }
    }

    /// `nil` when the bearer token is live; otherwise HQBase's 401.
    private func authenticate(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse? {
        let bearer = request.header("Authorization").flatMap { header -> String? in
            guard header.hasPrefix("Bearer ") else { return nil }
            return String(header.dropFirst("Bearer ".count))
        }
        if let bearer, let id = state.accessIndex[bearer], let grant = state.grants[id],
           grant.condition == .live, state.clients[grant.clientID] == true {
            return nil
        }
        state.counters.unauthorized += 1
        return .error(
            401,
            code: "INVALID_OAUTH_TOKEN",
            message: "Invalid OAuth access token",
            headers: [
                "WWW-Authenticate":
                    #"Bearer resource_metadata="\#(origin.absoluteString)/.well-known/oauth-protected-resource/api/v1", scope="mail:read", error="invalid_token""#,
            ]
        )
    }

    // MARK: Mail API

    private func mailAPI(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        let parts = request.path.dropFirst("/api/v1/".count).split(separator: "/").map(String.init)
        let withLabels = request.query["includeLabels"] == "true"
        switch (request.method, parts.count, parts.first ?? "") {
        case ("GET", 1, "mailboxes"):
            return .json(200, [mailboxJSON()])
        case ("GET", 1, "labels"):
            return .json(200, [Any]())
        case ("GET", 1, "changes"):
            return changes(request, state: &state, withLabels: withLabels)
        case ("GET", 1, "conversations"):
            return conversations(request, state: state, withLabels: withLabels)
        case ("GET", 1, "messages"):
            return listMessages(request, state: state, withLabels: withLabels)
        case ("GET", 2, "messages"):
            guard let message = state.message(parts[1]) else { return .notFound("MESSAGE_NOT_FOUND") }
            return .json(200, detailJSON(message, withLabels: withLabels))
        case ("GET", 3, "messages") where parts[2] == "thread":
            guard let message = state.message(parts[1]) else { return .notFound("MESSAGE_NOT_FOUND") }
            let thread = state.messages.filter { $0.threadId == message.threadId }.sorted { $0.date < $1.date }
            return .json(200, thread.map { detailJSON($0, withLabels: withLabels) })
        case ("GET", 3, "messages") where parts[2] == "html":
            guard let message = state.message(parts[1]) else { return .notFound("MESSAGE_NOT_FOUND") }
            return .json(200, [
                "html": "<p>\(Self.escapeHTML(message.text))</p>",
                "hasRemoteImages": false,
                "htmlHasRemoteImages": false,
                "quotedHtmlHasRemoteImages": false,
                "afterQuotedHtmlHasRemoteImages": false,
                "remoteMediaTrusted": false,
            ])
        case ("POST", 3, "messages"):
            guard let action = parts.last, Self.actions.contains(action) else {
                return .error(501, code: "NOT_IMPLEMENTED", message: "Not faked in UI tests")
            }
            guard state.message(parts[1]) != nil else { return .notFound("MESSAGE_NOT_FOUND") }
            state.apply(action, toMessage: parts[1])
            return .json(200, summaryJSON(state.message(parts[1])!, withLabels: withLabels))
        case ("POST", 3, "conversations"):
            guard let action = parts.last, Self.actions.contains(action) else {
                return .error(400, code: "INVALID_ACTION", message: "Unknown action")
            }
            guard let anchor = state.message(parts[1]) else { return .notFound("MESSAGE_NOT_FOUND") }
            let members = state.messages.filter { $0.threadId == anchor.threadId }.map(\.id)
            for id in members { state.apply(action, toMessage: id) }
            return .json(200, ["affected": members.count, "threadId": anchor.threadId])
        case ("GET", 1, "drafts"):
            return .json(200, state.drafts.values.sorted { $0.updatedAt > $1.updatedAt }.map(draftJSON))
        case ("POST", 1, "drafts"):
            return createDraft(request, state: &state)
        case ("GET", 2, "drafts"):
            guard let draft = state.drafts[parts[1]] else { return .notFound("DRAFT_NOT_FOUND") }
            return .json(200, draftJSON(draft))
        case ("PATCH", 2, "drafts"):
            return updateDraft(parts[1], request, state: &state)
        case ("DELETE", 2, "drafts"):
            guard state.drafts.removeValue(forKey: parts[1]) != nil else { return .notFound("DRAFT_NOT_FOUND") }
            state.counters.draftDeletes += 1
            return FakeHTTPResponse(status: 204)
        case ("POST", 1, "send"), ("POST", 1, "reply"), ("POST", 1, "forward"):
            return send(kind: parts[0], request, state: &state, withLabels: withLabels)
        case ("GET", 1, "signatures"):
            guard let from = request.query["from"], !from.isEmpty else {
                return .error(400, code: "SIGNATURE_INVALID", message: "from is required")
            }
            guard from.caseInsensitiveCompare(mailboxAddress) == .orderedSame else {
                return .notFound("MAILBOX_NOT_FOUND")
            }
            return .json(200, ["signatures": [Any]()])
        case ("GET", 2, "signatures") where parts[1] == "manage":
            // Needs `signatures:manage`, which this server (like 1.4.0) does not grant.
            return .error(
                403,
                code: "INSUFFICIENT_SCOPE",
                message: "signatures:manage required",
                headers: [
                    "WWW-Authenticate":
                        #"Bearer resource_metadata="\#(origin.absoluteString)/.well-known/oauth-protected-resource/api/v1", scope="signatures:manage", error="insufficient_scope""#,
                ]
            )
        default:
            return .error(501, code: "NOT_IMPLEMENTED", message: "\(request.method) \(request.path) is not faked in UI tests")
        }
    }

    private static let actions: Set<String> = ["read", "unread", "star", "unstar", "archive", "unarchive", "trash", "restore"]

    private func changes(_ request: FakeHTTPRequest, state: inout ServerState, withLabels: Bool) -> FakeHTTPResponse {
        guard let cursor = request.query["cursor"] else {
            return .json(200, ["changes": [Any](), "nextCursor": "j\(state.journalSeq)", "hasMore": false])
        }
        // HQBase: a cursor it cannot read is 400 `INVALID_CHANGE_CURSOR`
        // (`AuthenticatingMiddleware` maps both codes to `.cursorExpired`).
        guard cursor.hasPrefix("j"), let since = Int(cursor.dropFirst()), since <= state.journalSeq else {
            return .error(400, code: "INVALID_CHANGE_CURSOR", message: "The change cursor is not valid")
        }
        var seen = Set<String>()
        let ids = state.journal.filter { $0.seq > since }.reversed().compactMap { entry -> String? in
            seen.insert(entry.messageID).inserted ? entry.messageID : nil
        }.reversed()
        let upserts: [[String: Any]] = ids.compactMap { id in
            state.message(id).map { ["type": "upsert", "message": summaryJSON($0, withLabels: withLabels)] }
        }
        return .json(200, ["changes": upserts, "nextCursor": "j\(state.journalSeq)", "hasMore": false])
    }

    private func conversations(_ request: FakeHTTPRequest, state: ServerState, withLabels: Bool) -> FakeHTTPResponse {
        if request.query["labelId"] != nil || request.query["labelIds"] != nil {
            return .json(200, ["conversations": [Any]()])
        }
        let folder = request.query["folder"] ?? "inbox"
        let matching = state.messages.filter { message in
            if let mailbox = request.query["mailboxId"], message.mailboxId != mailbox { return false }
            if let search = request.query["search"], !search.isEmpty, !message.matches(search) { return false }
            return folder == "starred" ? message.starredAt != nil && message.folder != "trash" : message.folder == folder
        }
        let threads = Dictionary(grouping: matching, by: \.threadId)
        let rows: [(Date, [String: Any])] = threads.values.compactMap { members in
            guard let latest = members.max(by: { $0.date < $1.date }) else { return nil }
            var row = summaryJSON(latest, withLabels: withLabels)
            row["isStarred"] = members.contains { $0.starredAt != nil }
            row["messageCount"] = members.count
            row["unreadCount"] = members.filter { $0.direction == "inbound" && $0.readAt == nil }.count
            return (latest.date, row)
        }
        return .json(200, ["conversations": rows.sorted { $0.0 > $1.0 }.map(\.1)])
    }

    private func listMessages(_ request: FakeHTTPRequest, state: ServerState, withLabels: Bool) -> FakeHTTPResponse {
        if request.query["labelId"] != nil || request.query["labelIds"] != nil { return .json(200, [Any]()) }
        let rows = state.messages.filter { message in
            if let folder = request.query["folder"], message.folder != folder { return false }
            if let mailbox = request.query["mailboxId"], message.mailboxId != mailbox { return false }
            if let search = request.query["search"], !search.isEmpty, !message.matches(search) { return false }
            return true
        }
        return .json(200, rows.sorted { $0.date > $1.date }.map { summaryJSON($0, withLabels: withLabels) })
    }

    private func createDraft(_ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        guard let body = Self.jsonObject(request.body) else {
            return .error(400, code: "VALIDATION_ERROR", message: "body is not JSON")
        }
        if let refusal = signatureRefusal(body) { return refusal }
        state.serial += 1
        var draft = DraftRecord(id: "drf_\(state.serial)", version: 1, updatedAt: Date())
        draft.apply(body)
        state.drafts[draft.id] = draft
        state.counters.draftCreates += 1
        return .json(201, draftJSON(draft))
    }

    private func updateDraft(_ id: String, _ request: FakeHTTPRequest, state: inout ServerState) -> FakeHTTPResponse {
        guard var draft = state.drafts[id] else { return .notFound("DRAFT_NOT_FOUND") }
        guard let body = Self.jsonObject(request.body) else {
            return .error(400, code: "VALIDATION_ERROR", message: "body is not JSON")
        }
        if let refusal = signatureRefusal(body) { return refusal }
        if let version = body["version"] as? Int, version != draft.version {
            return .error(409, code: "DRAFT_CONFLICT", message: "The draft changed since it was loaded")
        }
        draft.apply(body)
        draft.version += 1
        draft.updatedAt = Date()
        state.drafts[id] = draft
        state.counters.draftUpdates += 1
        return .json(200, draftJSON(draft))
    }

    /// This server has no signatures, so a `selected` one is never usable.
    private func signatureRefusal(_ body: [String: Any]) -> FakeHTTPResponse? {
        guard let selection = body["signature"] as? [String: Any], selection["mode"] as? String == "selected" else {
            return nil
        }
        return .error(400, code: "SIGNATURE_NOT_AVAILABLE", message: "That signature is not available")
    }

    private func send(kind: String, _ request: FakeHTTPRequest, state: inout ServerState, withLabels: Bool) -> FakeHTTPResponse {
        guard let body = Self.jsonObject(request.body) else {
            return .error(400, code: "VALIDATION_ERROR", message: "body is not JSON")
        }
        let canonical = Self.canonical(body)
        let key = (body["idempotencyKey"] as? String).map { "\(kind):\($0)" }
        if let key, let stored = state.sendKeys[key] {
            // Same principal + key: the stored 201 for an identical body, a
            // conflict for a different one (1.4.0 `send/operations.ts`).
            guard stored.body == canonical else {
                return .error(409, code: "SEND_KEY_CONFLICT", message: "This idempotency key was used for a different message")
            }
            return FakeHTTPResponse(status: 201, headers: ["Content-Type": "application/json"], body: stored.response)
        }
        if let refusal = signatureRefusal(body) { return refusal }
        let from = body["from"] as? String ?? mailboxAddress
        guard from.caseInsensitiveCompare(mailboxAddress) == .orderedSame else {
            return .error(403, code: "MAILBOX_FORBIDDEN", message: "You cannot send from \(from)")
        }
        let text = body["text"] as? String ?? ""
        var to = body["to"] as? [String] ?? []
        var subject = (body["subject"] as? String) ?? ""
        var threadID: String?
        switch kind {
        case "reply", "forward":
            guard let original = (body["messageId"] as? String).flatMap(state.message) else {
                return .notFound("MESSAGE_NOT_FOUND")
            }
            if kind == "reply" {
                threadID = original.threadId
                if to.isEmpty { to = [original.fromAddress] }
                if subject.isEmpty { subject = "Re: \(original.subject)" }
            } else if subject.isEmpty {
                subject = "Fwd: \(original.subject)"
            }
            guard !to.isEmpty else { return .error(400, code: "VALIDATION_ERROR", message: "to: at least one recipient") }
        default:
            guard !to.isEmpty else { return .error(400, code: "VALIDATION_ERROR", message: "to: at least one recipient") }
            guard !subject.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .error(400, code: "VALIDATION_ERROR", message: "subject: required")
            }
            guard !text.isEmpty else { return .error(400, code: "VALIDATION_ERROR", message: "text: required") }
        }
        if let draftID = body["draftId"] as? String {
            guard state.drafts.removeValue(forKey: draftID) != nil else { return .notFound("DRAFT_NOT_FOUND") }
        }
        state.serial += 1
        let now = Date()
        let id = "msg_sent_\(state.serial)"
        let message = MessageRecord(
            id: id,
            threadId: threadID ?? "thr_\(id)",
            mailboxId: mailboxID,
            direction: "outbound",
            folder: "sent",
            fromAddress: mailboxAddress,
            fromName: nil,
            to: to,
            subject: subject,
            text: text,
            receivedAt: nil,
            sentAt: now,
            readAt: now,
            starredAt: nil,
            createdAt: now
        )
        state.insert(message)
        state.counters.sends += 1
        let response = Self.data(summaryJSON(message, withLabels: withLabels))
        if let key { state.sendKeys[key] = (canonical, response) }
        return FakeHTTPResponse(status: 201, headers: ["Content-Type": "application/json"], body: response)
    }

    // MARK: Wire shapes (openapi.json)

    private func mailboxJSON() -> [String: Any] {
        let created = Self.iso(Date(timeIntervalSince1970: 1_767_225_600))
        return [
            "id": mailboxID,
            "address": mailboxAddress,
            "addresses": [[
                "id": "adr_\(mailboxID)",
                "mailboxId": mailboxID,
                "mailDomainId": "dom_\(mailboxID)",
                "address": mailboxAddress,
                "displayName": "UI Test",
                "receiveEnabled": true,
                "sendEnabled": true,
                "isPrimary": true,
            ]],
            "displayName": "UI Test",
            "isActive": true,
            "accessLevel": "manager",
            "createdAt": created,
            "updatedAt": created,
        ]
    }

    private func summaryJSON(_ message: MessageRecord, withLabels: Bool) -> [String: Any] {
        var row: [String: Any] = [
            "id": message.id,
            "threadId": message.threadId,
            "mailboxId": message.mailboxId,
            "direction": message.direction,
            "folder": message.folder,
            "fromAddress": message.fromAddress,
            "to": message.to,
            "subject": message.subject,
            "snippet": String(message.text.prefix(120)),
            "hasAttachments": false,
            "createdAt": Self.iso(message.createdAt),
        ]
        row["fromName"] = message.fromName
        row["receivedAt"] = message.receivedAt.map(Self.iso)
        row["sentAt"] = message.sentAt.map(Self.iso)
        row["readAt"] = message.readAt.map(Self.iso)
        row["starredAt"] = message.starredAt.map(Self.iso)
        if withLabels { row["labels"] = [Any]() }
        return row
    }

    private func detailJSON(_ message: MessageRecord, withLabels: Bool) -> [String: Any] {
        var row = summaryJSON(message, withLabels: withLabels)
        row["cc"] = [String]()
        row["bcc"] = [String]()
        row["textBody"] = message.text
        row["htmlAvailable"] = true
        row["messageId"] = "<\(message.id)@\(host)>"
        row["references"] = [String]()
        row["attachments"] = [Any]()
        if message.direction == "inbound" { row["deliveredToAddress"] = mailboxAddress }
        return row
    }

    private func draftJSON(_ draft: DraftRecord) -> [String: Any] {
        var row: [String: Any] = [
            "id": draft.id,
            "version": draft.version,
            "updatedAt": Self.iso(draft.updatedAt),
            "attachments": [Any](),
            "signature": ["mode": draft.signatureMode, "name": "", "html": "", "text": ""],
            "labels": [Any](),
            "from": draft.from.isEmpty ? mailboxAddress : draft.from,
            "to": draft.to,
            "cc": draft.cc,
            "bcc": draft.bcc,
            "subject": draft.subject,
            "text": draft.text,
            "html": draft.html,
        ]
        row["mailboxId"] = draft.mailboxId ?? mailboxID
        row["replyToMessageId"] = draft.replyToMessageId
        row["forwardOfMessageId"] = draft.forwardOfMessageId
        return row
    }

    // MARK: Encoding helpers

    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func iso(_ date: Date) -> String { isoStyle.format(date) }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Key-order-independent form of a JSON body, for idempotent-replay checks.
    static func canonical(_ object: [String: Any]) -> Data { data(object) }

    static func form(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            guard let name = parts.first else { continue }
            fields[name] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func oauthError(_ status: Int, _ error: String, _ description: String?) -> FakeHTTPResponse {
        var body: [String: Any] = ["error": error]
        body["error_description"] = description
        return .json(status, body)
    }

    private static func tokenResponse(_ tokens: OAuthTokens) -> FakeHTTPResponse {
        var body: [String: Any] = [
            "access_token": tokens.accessToken,
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": tokens.scope,
        ]
        body["refresh_token"] = tokens.refreshToken
        return .json(200, body)
    }
}

// MARK: - Server state

private nonisolated enum GrantCondition: Sendable {
    case live, sessionDead, revoked, proxy401
    /// Revoked by the client itself (`/revoke` at sign-out): no server state
    /// brings it back.
    case revokedByClient
}

private nonisolated struct Grant: Sendable {
    let clientID: String
    let scope: String
    var refreshToken: String
    var condition: GrantCondition
}

private nonisolated struct CodeRecord: Sendable {
    let clientID: String
    let redirectURI: String
    let challenge: String
    let resource: String
    let scope: String
}

private nonisolated struct MessageRecord: Sendable {
    let id: String
    let threadId: String
    let mailboxId: String
    let direction: String
    var folder: String
    let fromAddress: String
    let fromName: String?
    let to: [String]
    let subject: String
    let text: String
    let receivedAt: Date?
    let sentAt: Date?
    var readAt: Date?
    var starredAt: Date?
    let createdAt: Date

    var date: Date { receivedAt ?? sentAt ?? createdAt }

    func matches(_ search: String) -> Bool {
        ([subject, text, fromAddress, fromName ?? ""] + to).contains { $0.localizedCaseInsensitiveContains(search) }
    }
}

private nonisolated struct DraftRecord: Sendable {
    let id: String
    var version: Int
    var updatedAt: Date
    var mailboxId: String?
    var replyToMessageId: String?
    var forwardOfMessageId: String?
    var from = ""
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var text = ""
    var html = ""
    var signatureMode = "none"

    init(id: String, version: Int, updatedAt: Date) {
        self.id = id
        self.version = version
        self.updatedAt = updatedAt
    }

    mutating func apply(_ body: [String: Any]) {
        if let value = body["mailboxId"] as? String { mailboxId = value }
        if let value = body["replyToMessageId"] as? String { replyToMessageId = value }
        if let value = body["forwardOfMessageId"] as? String { forwardOfMessageId = value }
        if let value = body["from"] as? String { from = value }
        if let value = body["to"] as? [String] { to = value }
        if let value = body["cc"] as? [String] { cc = value }
        if let value = body["bcc"] as? [String] { bcc = value }
        if let value = body["subject"] as? String { subject = value }
        if let value = body["text"] as? String { text = value }
        if let value = body["html"] as? String { html = value }
        if let selection = body["signature"] as? [String: Any], let mode = selection["mode"] as? String {
            signatureMode = mode
        }
    }
}

private nonisolated struct ServerState {
    var mode: FakeHQBaseState = .healthy
    var observer: (@Sendable () -> Void)?
    var counters = FakeHQBaseCounters()
    var serial = 0
    var clients: [String: Bool] = [:]
    var grants: [Int: Grant] = [:]
    var accessIndex: [String: Int] = [:]
    var refreshIndex: [String: Int] = [:]
    var codes: [String: CodeRecord] = [:]
    var messages: [MessageRecord] = []
    var drafts: [String: DraftRecord] = [:]
    var journal: [(seq: Int, messageID: String)] = []
    var journalSeq = 0
    var sendKeys: [String: (body: Data, response: Data)] = [:]

    func message(_ id: String) -> MessageRecord? { messages.first { $0.id == id } }

    mutating func insert(_ message: MessageRecord) {
        messages.append(message)
        record(message.id)
    }

    mutating func record(_ messageID: String) {
        journalSeq += 1
        journal.append((journalSeq, messageID))
    }

    mutating func apply(_ action: String, toMessage id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        switch action {
        case "read": messages[index].readAt = messages[index].readAt ?? now
        case "unread": messages[index].readAt = nil
        case "star": messages[index].starredAt = messages[index].starredAt ?? now
        case "unstar": messages[index].starredAt = nil
        case "archive": messages[index].folder = "archived"
        case "unarchive", "restore":
            messages[index].folder = messages[index].direction == "outbound" ? "sent" : "inbox"
        case "trash": messages[index].folder = "trash"
        default: return
        }
        record(id)
    }

    mutating func mintTokens(scope: String, host: String) -> OAuthTokens {
        serial += 1
        let tag = host.split(separator: ".").first ?? "x"
        return OAuthTokens(
            accessToken: "uitest-at-\(tag)-\(serial)",
            refreshToken: "uitest-rt-\(tag)-\(serial)",
            expiresAt: Date().addingTimeInterval(3600),
            scope: scope
        )
    }

    mutating func mintGrant(clientID: String, scope: String, host: String) -> OAuthTokens {
        let tokens = mintTokens(scope: scope, host: host)
        let id = serial
        grants[id] = Grant(clientID: clientID, scope: scope, refreshToken: tokens.refreshToken ?? "", condition: .live)
        accessIndex[tokens.accessToken] = id
        refreshIndex[tokens.refreshToken ?? ""] = id
        return tokens
    }
}

private nonisolated extension FakeHTTPResponse {
    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> FakeHTTPResponse {
        FakeHTTPResponse(
            status: status,
            headers: headers.merging(["Content-Type": "application/json"]) { existing, _ in existing },
            body: FakeHQBase.data(object)
        )
    }

    /// The Mail API's `{"error":{"code","message"}}` envelope.
    static func error(_ status: Int, code: String, message: String, headers: [String: String] = [:]) -> FakeHTTPResponse {
        json(status, ["error": ["code": code, "message": message]], headers: headers)
    }

    static func notFound(_ code: String) -> FakeHTTPResponse {
        error(404, code: code, message: "Not found")
    }
}
#endif
