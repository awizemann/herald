import Foundation

/// One canned HTTP response.
nonisolated struct FakeResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int = 200, _ raw: String, headers: [String: String] = [:]) -> FakeResponse {
        FakeResponse(
            status: status,
            headers: headers.merging(["Content-Type": "application/json"]) { existing, _ in existing },
            body: Data(raw.utf8)
        )
    }

    /// The API's `{"error":{"code","message"}}` envelope.
    static func error(
        _ status: Int,
        code: String,
        message: String,
        headers: [String: String] = [:]
    ) -> FakeResponse {
        .json(status, #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#, headers: headers)
    }
}

/// A request as the fake server saw it.
nonisolated struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: String?
    var headers: [String: String]
    var body: Data

    var authorization: String? { headers["Authorization"] }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
    /// Body with all whitespace removed — the OpenAPI runtime pretty-prints JSON,
    /// so assertions should not depend on its spacing.
    var compactBodyText: String { bodyText.filter { !$0.isWhitespace } }
}

/// Thread-safe route table + request log shared by ``FakeServerProtocol``.
///
/// Routes are keyed by `(method, path)` — path only, so query strings are recorded
/// but do not have to be spelled out in the route key. A route may hold several
/// responses: they are handed out in order and the last one repeats, which is how
/// the 401-then-200 refresh case is expressed.
nonisolated final class FakeServer: @unchecked Sendable {
    private struct Key: Hashable {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var routes: [Key: [FakeResponse]] = [:]
    private var hits: [Key: Int] = [:]
    private var recorded: [RecordedRequest] = []

    /// Registers the sequence of responses for a route (last one repeats).
    func route(_ method: String, _ path: String, _ responses: FakeResponse...) {
        lock.withLock {
            routes[Key(method: method.uppercased(), path: path)] = responses
            hits[Key(method: method.uppercased(), path: path)] = 0
        }
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func requests(path: String) -> [RecordedRequest] {
        lock.withLock { recorded.filter { $0.path == path } }
    }

    fileprivate func respond(to request: RecordedRequest) -> FakeResponse {
        lock.withLock {
            recorded.append(request)
            let key = Key(method: request.method, path: request.path)
            guard let responses = routes[key], !responses.isEmpty else {
                return .error(501, code: "no_route", message: "\(request.method) \(request.path)")
            }
            let index = min(hits[key, default: 0], responses.count - 1)
            hits[key] = hits[key, default: 0] + 1
            return responses[index]
        }
    }

    // MARK: - URLSession wiring

    /// A session whose every request is answered by this server.
    ///
    /// The routing token travels as a request header (via `httpAdditionalHeaders`)
    /// so suites running in parallel never answer each other's requests.
    func makeSession() -> URLSession {
        let token = FakeServerProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServerProtocol.self]
        configuration.httpAdditionalHeaders = [FakeServerProtocol.tokenHeader: token]
        return URLSession(configuration: configuration)
    }

    static let origin = URL(string: "https://mail.test.invalid")!
}

/// `URLProtocol` that answers from the ``FakeServer`` bound to its session.
nonisolated final class FakeServerProtocol: URLProtocol, @unchecked Sendable {
    static let tokenHeader = "X-Fake-Server"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var servers: [String: FakeServer] = [:]

    /// Returns the token that routes a request back to `server`.
    static func register(_ server: FakeServer) -> String {
        let token = UUID().uuidString
        lock.withLock { servers[token] = server }
        return token
    }

    private static func server(for request: URLRequest) -> FakeServer? {
        guard let token = request.value(forHTTPHeaderField: tokenHeader) else { return nil }
        return lock.withLock { servers[token] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let recorded = RecordedRequest(
            method: request.httpMethod?.uppercased() ?? "GET",
            path: components?.path ?? url.path,
            query: components?.query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(of: request)
        )
        let response = server.respond(to: recorded)

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLProtocol` hands streamed bodies over `httpBodyStream`, which is how the
    /// OpenAPI URLSession transport uploads JSON and multipart payloads.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        // Read until EOF rather than polling `hasBytesAvailable`: the OpenAPI
        // URLSession transport streams request bodies through a bound pair, so the
        // first bytes have not arrived yet when the protocol starts loading and
        // `hasBytesAvailable` is still false.
        while true {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
