import Foundation

/// Realistic response bodies shaped exactly like the v1 spec's schemas.
/// Nullable fields are present-and-null on purpose so mapping tests can prove
/// they survive as `nil` rather than being silently dropped.
nonisolated enum Fixtures {
    /// Unread, unstarred inbound message with an inline attachment.
    static let messageDetailJSON = """
    {
      "id": "msg_01",
      "threadId": "thr_09",
      "mailboxId": "mbx_support",
      "direction": "inbound",
      "folder": "inbox",
      "fromAddress": "ada@example.net",
      "to": ["support@example.com"],
      "subject": "Invoice question",
      "snippet": "Hi there, about invoice 4471…",
      "receivedAt": "2026-08-14T09:30:00.000Z",
      "sentAt": null,
      "readAt": null,
      "starredAt": null,
      "hasAttachments": true,
      "createdAt": "2026-08-14T09:30:01.000Z",
      "cc": ["billing@example.com"],
      "bcc": [],
      "deliveredToAddress": "support@example.com",
      "textBody": "Hi there, about invoice 4471.",
      "htmlAvailable": true,
      "messageId": "<abc@example.net>",
      "inReplyTo": null,
      "references": ["<root@example.net>"],
      "attachments": [
        {
          "id": "att_1",
          "messageId": "msg_01",
          "filename": "logo.png",
          "contentType": "image/png",
          "sizeBytes": 1234,
          "contentId": "logo@cid",
          "createdAt": "2026-08-14T09:30:02.000Z"
        },
        {
          "id": "att_2",
          "messageId": "msg_01",
          "filename": "invoice.pdf",
          "contentType": "application/pdf",
          "sizeBytes": 88000,
          "contentId": null,
          "createdAt": "2026-08-14T09:30:02.000Z"
        }
      ]
    }
    """

    /// Two threads: one unread/unstarred, one read/starred. `nextCursor` non-null,
    /// `totalCount` null — the combination that catches "cursor was dropped".
    static let conversationPageJSON = """
    {
      "conversations": [
        {
          "id": "msg_01",
          "threadId": "thr_09",
          "mailboxId": null,
          "direction": "inbound",
          "folder": "inbox",
          "fromAddress": "ada@example.net",
          "to": ["support@example.com"],
          "subject": "Invoice question",
          "snippet": "Hi there…",
          "receivedAt": "2026-08-14T09:30:00.000Z",
          "sentAt": null,
          "readAt": null,
          "starredAt": null,
          "hasAttachments": true,
          "createdAt": "2026-08-14T09:30:01.000Z",
          "isStarred": false,
          "messageCount": 3,
          "unreadCount": 2
        },
        {
          "id": "msg_05",
          "threadId": "thr_11",
          "mailboxId": "mbx_support",
          "direction": "outbound",
          "folder": "sent",
          "fromAddress": "support@example.com",
          "to": ["grace@example.org"],
          "subject": "Re: Onboarding",
          "snippet": "Sounds good…",
          "receivedAt": null,
          "sentAt": "2026-08-13T18:00:00.000Z",
          "readAt": "2026-08-13T18:05:00.000Z",
          "starredAt": "2026-08-13T18:06:00.000Z",
          "hasAttachments": false,
          "createdAt": "2026-08-13T18:00:00.000Z",
          "isStarred": true,
          "messageCount": 1,
          "unreadCount": 0
        }
      ],
      "nextCursor": "eyJvIjoyfQ",
      "totalCount": null
    }
    """

    /// Mailbox with a null accessLevel plus one with a real one.
    static let mailboxesJSON = """
    [
      {
        "id": "mbx_support",
        "address": "support@example.com",
        "addresses": [
          {
            "id": "adr_1",
            "mailboxId": "mbx_support",
            "mailDomainId": "dom_1",
            "address": "support@example.com",
            "displayName": "Support",
            "receiveEnabled": true,
            "sendEnabled": true,
            "isPrimary": true
          }
        ],
        "displayName": "Support",
        "isActive": true,
        "accessLevel": "manager",
        "createdAt": "2026-01-02T03:04:05.000Z",
        "updatedAt": "2026-02-02T03:04:05.000Z"
      },
      {
        "id": "mbx_catchall",
        "address": "catchall@example.com",
        "addresses": [],
        "displayName": "Catch-all",
        "isActive": false,
        "accessLevel": null,
        "createdAt": "2026-01-02T03:04:05.000Z",
        "updatedAt": "2026-01-02T03:04:05.000Z"
      }
    ]
    """

    static let draftAttachmentJSON = """
    {"id":"datt_7","filename":"quote.txt","contentType":"text/plain","sizeBytes":11}
    """

    static let messageHTMLJSON = """
    {"hasRemoteImages":true,"html":"<p>Hi</p>","quotedHtml":null,"remoteMediaTrusted":false}
    """

    /// Parses an ISO-8601 instant, so date assertions state the wire value literally.
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }
}
