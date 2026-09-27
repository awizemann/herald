#if DEBUG
import Foundation
import HeraldKit
import os

/// The in-process network of the UI-test mode: a set of ``FakeHQBase`` servers
/// keyed by host, reachable ONLY through the sessions ``makeSession()`` builds.
///
/// `FakeHQBaseProtocol` is never registered globally (`URLProtocol.registerClass`)
/// — it is the sole entry of each harness session's `protocolClasses`, and its
/// `canInit` answers `true` for everything, so a request on such a session can
/// never reach the real network: an unknown host gets a transport error.
nonisolated final class FakeHQBaseNetwork: @unchecked Sendable {
    /// Header that routes a request back to its network, so parallel harnesses
    /// (unit tests) never answer each other's traffic. Stripped of meaning
    /// outside this process.
    static let routingHeader = "X-Herald-UITest-Network"

    private let servers: [String: FakeHQBase]
    private let token = UUID().uuidString

    init(servers: [FakeHQBase]) {
        self.servers = Dictionary(servers.map { ($0.host.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        FakeHQBaseProtocol.register(self, token: token)
    }

    deinit { FakeHQBaseProtocol.unregister(token: token) }

    var all: [FakeHQBase] { servers.values.sorted { $0.host < $1.host } }

    func server(for url: URL) -> FakeHQBase? {
        url.host.flatMap { servers[$0.lowercased()] }
    }

    /// An ephemeral session answered only by this network: no cache, no
    /// cookies, auth-sized timeouts.
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHQBaseProtocol.self]
        configuration.httpAdditionalHeaders = [Self.routingHeader: token]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}

/// Answers from the ``FakeHQBaseNetwork`` named by the request's routing header.
nonisolated final class FakeHQBaseProtocol: URLProtocol, @unchecked Sendable {
    private static let networks = OSAllocatedUnfairLock(initialState: [String: WeakNetwork]())

    private struct WeakNetwork: @unchecked Sendable {
        weak var network: FakeHQBaseNetwork?
    }

    static func register(_ network: FakeHQBaseNetwork, token: String) {
        networks.withLock { $0[token] = WeakNetwork(network: network) }
    }

    static func unregister(token: String) {
        networks.withLock { $0[token] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let token = request.value(forHTTPHeaderField: FakeHQBaseNetwork.routingHeader),
              let network = Self.networks.withLock({ $0[token]?.network }),
              let server = network.server(for: url)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            client?.urlProtocol(self, didFailWithError: URLError(.appTransportSecurityRequiresSecureConnection))
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        // A held refresh (``FakeHQBase/holdRefreshResponses()``) is delivered
        // later from the releasing thread; URLProtocol wants its client told on
        // the loading thread, so that delivery hops back onto its run loop.
        let loadingRunLoop = LoadingRunLoop(CFRunLoopGetCurrent())
        server.respond(to: FakeHTTPRequest(
            method: request.httpMethod?.uppercased() ?? "GET",
            path: components?.path ?? url.path,
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(of: request)
        )) { [weak self] response in
            loadingRunLoop.run { [weak self] in self?.deliver(response, for: url) }
        }
    }

    /// The loading thread's run loop, carried to the releasing thread.
    private struct LoadingRunLoop: @unchecked Sendable {
        let runLoop: CFRunLoop
        init(_ runLoop: CFRunLoop) { self.runLoop = runLoop }
        /// Inline when already on the loading thread (every answer but a
        /// released hold), else scheduled onto its run loop.
        func run(_ block: @escaping @Sendable () -> Void) {
            if CFRunLoopGetCurrent() === runLoop { return block() }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    private func deliver(_ response: FakeHTTPResponse, for url: URL) {
        // A task cancelled while its refresh was held must not hear back.
        guard !stopped.withLock({ $0 }) else { return }
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    /// URLSession hands streamed bodies (the OpenAPI transport's JSON uploads)
    /// over `httpBodyStream`; read to EOF.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The wake socket's opener in test mode. A WebSocket upgrade never passes
/// through `URLProtocol`, so the fake cannot serve `GET /events`; it refuses
/// it the way HQBase does when its event service is unavailable (503,
/// "Continue with HTTP synchronization"). `MailEventSocket` then backs off and
/// polling carries the app — no socket, no real connection.
nonisolated struct FakeEventChannels: MailEventChannelOpening {
    let server: FakeHQBase?

    func open(token: String) async throws -> any MailEventChannel {
        server?.refuseEventsUpgrade()
        throw MailEventChannelError.rejected(status: 503)
    }
}
#endif
