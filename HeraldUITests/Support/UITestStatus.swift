import Foundation

/// A parsed `uitest.status` value: space-separated `key=value` pairs
/// (`server=healthy presenter=succeed sends=0 …`, see `UITestHarness.status`).
/// Keys are only ever APPENDED on the app side, so parsing is by key, never by
/// position, and an unknown key is simply carried along.
struct UITestStatus: Equatable, CustomStringConvertible, Sendable {
    /// The raw value it was parsed from.
    let raw: String
    let fields: [String: String]

    /// The keys every harness since U1 reports.
    static let requiredKeys = [
        "server", "presenter", "sends", "sendRequests", "tokenRequests", "refreshes",
        "codeExchanges", "registrations", "signIns", "pendingSignIns", "draftCreates",
        "draftUpdates", "draftDeletes", "unauthorized", "revocations", "storeRefusesList",
    ]

    /// `nil` unless every token is `key=value` and every ``requiredKeys`` key
    /// is there — a half-rendered or foreign value never parses.
    init?(_ raw: String) {
        var fields: [String: String] = [:]
        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return nil }
            fields[String(token[..<equals])] = String(token[token.index(after: equals)...])
        }
        guard Self.requiredKeys.allSatisfy({ fields[$0] != nil }) else { return nil }
        self.raw = raw
        self.fields = fields
    }

    subscript(key: String) -> String? { fields[key] }

    /// A counter; `nil` when the key is missing or not an integer.
    func count(_ key: String) -> Int? { fields[key].flatMap(Int.init) }

    var server: String? { fields["server"] }
    var presenter: String? { fields["presenter"] }
    var storeRefusesList: Bool? { fields["storeRefusesList"].flatMap(Bool.init) }

    var sends: Int? { count("sends") }
    var sendRequests: Int? { count("sendRequests") }
    var tokenRequests: Int? { count("tokenRequests") }
    var refreshes: Int? { count("refreshes") }
    var codeExchanges: Int? { count("codeExchanges") }
    var registrations: Int? { count("registrations") }
    var signIns: Int? { count("signIns") }
    var pendingSignIns: Int? { count("pendingSignIns") }
    var draftCreates: Int? { count("draftCreates") }
    var draftUpdates: Int? { count("draftUpdates") }
    var draftDeletes: Int? { count("draftDeletes") }
    var unauthorized: Int? { count("unauthorized") }
    var revocations: Int? { count("revocations") }

    var description: String { raw }
}
