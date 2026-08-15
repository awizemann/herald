import Foundation
import OpenAPIRuntime

/// Date handling for the HQBase wire format.
///
/// HQBase is a Cloudflare Worker, so every timestamp is JavaScript's
/// `Date.toISOString()` — always with milliseconds (`2026-08-14T09:30:00.000Z`).
/// The OpenAPI runtime's default transcoder only accepts ISO-8601 *without*
/// fractional seconds, so every date-bearing response would fail to decode.
/// This transcoder accepts both and emits the millisecond form.
nonisolated struct HQBaseDateTranscoder: DateTranscoder {
    /// `ISO8601FormatStyle` is a Sendable value type, unlike `ISO8601DateFormatter`.
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    func encode(_ date: Date) throws -> String {
        Self.withFractionalSeconds.format(date)
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Self.withFractionalSeconds.parse(string) { return date }
        if let date = try? Self.withoutFractionalSeconds.parse(string) { return date }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Not an ISO-8601 date: \(string)")
        )
    }
}
