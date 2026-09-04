import Foundation

/// The colour a label is drawn in. A CLOSED set on the server (`labelColors` in
/// `worker/features/labels/queries.ts`).
///
/// ``init(serverValue:)`` folds an unknown name onto ``gray``. That protects the
/// CACHE read path — `CachedLabel.colorRaw` is a plain stored string, and an
/// older build's value must still draw. It does NOT rescue a wire response: the
/// vendored spec declares the enum closed, so a server that ships an eleventh
/// colour fails the whole `GET /labels` decode.
public nonisolated enum LabelColor: String, Sendable, Hashable, Codable, CaseIterable {
    case gray, red, orange, amber, green, teal, blue, indigo, purple, pink

    /// The fallback for a colour this build does not know.
    public static let fallback = LabelColor.gray

    public init(serverValue: String) {
        self = LabelColor(rawValue: serverValue) ?? .fallback
    }
}

/// One workspace label.
///
/// Named `MailLabel`, not `Label`: SwiftUI's `Label` is used on every sidebar row
/// in this app and a same-named DTO would shadow it in every view file.
///
/// Labels are SHARED workspace-wide (one `labels` table, no per-user scoping) and
/// they are ORGANIZATION ONLY: assigning one never changes a message's folder and
/// never grants mailbox access. Creating, renaming and deleting them is a web-app
/// affair — the Mail API v1 exposes only `GET /labels` plus the per-resource
/// assignment routes, and the CRUD routes require an owner/admin cookie session.
public nonisolated struct MailLabel: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let color: LabelColor
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        color: LabelColor,
        createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What `PUT`/`DELETE /{messages|conversations|drafts}/{id}/labels/{labelId}`
/// answers with.
///
/// `labels` is the AUTHORITATIVE full set after the write — for a message its own
/// labels, for a conversation the DISTINCT union across every accessible message
/// of the thread — which is what lets an optimistic assignment reconcile without
/// a second request.
public nonisolated struct LabelAssignment: Sendable, Hashable {
    /// How many rows the write touched. `0` means the server accepted the request
    /// and changed nothing (the label was already in that state), NOT a failure.
    public let affected: Int
    /// Whether this was an add (`true`) or a remove.
    public let assigned: Bool
    public let labelID: String
    public let messageID: String?
    public let threadID: String?
    public let draftID: String?
    public let labels: [MailLabel]

    public init(
        affected: Int,
        assigned: Bool,
        labelID: String,
        messageID: String? = nil,
        threadID: String? = nil,
        draftID: String? = nil,
        labels: [MailLabel]
    ) {
        self.affected = affected
        self.assigned = assigned
        self.labelID = labelID
        self.messageID = messageID
        self.threadID = threadID
        self.draftID = draftID
        self.labels = labels
    }
}
