import Foundation
import Testing
@testable import HeraldKit

/// The attachment download route, on the wire. HQBase serves each attachment
/// with its own stored Content-Type, not the `application/octet-stream` the
/// upstream spec declares; `scripts/vendor-openapi.py` widens the route to `*/*`.
@Suite("Attachment download")
struct AttachmentDownloadTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    /// Fails if the generated client still insists on `application/octet-stream`:
    /// an `image/png` (or `application/pdf`) response then throws before the
    /// bytes are read, and Quick Look shows "a response Herald could not read".
    @Test("A download is read whatever Content-Type the server sends",
          arguments: ["image/png", "application/pdf", "application/octet-stream"])
    func readsAnyContentType(contentType: String) async throws {
        let server = FakeServer()
        server.route("GET", "/api/v1/attachments/att_1",
                     FakeResponse(headers: ["Content-Type": contentType], body: Self.png))
        let client = HQBaseAPIClient(origin: FakeServer.origin, tokens: FakeTokenProvider(), session: server.makeSession())

        let payload = try await client.attachmentData(id: "att_1")

        #expect(payload.data == Self.png)
        #expect(payload.mimeType == "image/png")
    }
}
