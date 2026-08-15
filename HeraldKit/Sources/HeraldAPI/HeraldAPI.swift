// HeraldAPI is a leaf module: it contains ONLY the swift-openapi-generator output for the
// vendored HQBase Mail API v1 spec (openapi.json). It deliberately builds with default
// NONISOLATED semantics (no defaultIsolation(MainActor)) because generated Hashable/Sendable
// conformances break under main-actor default isolation. HeraldKit wraps it behind
// `MailAPIClient` and never leaks generated types to the app.
