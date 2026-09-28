---
identity: |
  Herald is a native macOS mail-triage client for HQBase — a self-hosted shared-mailbox workspace. It is written for a single developer-owner who also dogfoods it, targeting power users running their own HQBase instance. Herald is not a general-purpose email client, not affiliated with the HQBase project, and does not support any mail protocol other than the HQBase Mail API v1.
commandments:
  - id: C1
    text: Never git-commit the managed memory tiers (.memory/, wiki/, design/, code/, sessions/, documents/, vendors/, templates/, TASKS.md, tasks/) — leave them dirty for the human to commit via Memophant's secret-scanned bar.
    rationale: Memophant's commit path runs a write-time secret scan; an agent commit bypasses it and can silently ship a credential.
    violations:
      - running `git add .memory/` or `git add TASKS.md`
      - including tasks/ in a feature commit with `git add -A`
      - amending a commit that already contains a managed-tier file
    see:
      - CLAUDE.md
      - AGENTS.md
  - id: C2
    text: Never add VersionedSchema, SchemaMigrationPlan, backup/restore parity, or NSFileCoordinator to the SwiftData store — recovery is always delete-and-re-sync.
    rationale: The store is a rebuildable cache; the server is the system of record. Migration machinery buys nothing and introduces risk; diverging from this will create false safety and future maintenance burden.
    violations:
      - introducing `VersionedSchema` or `SchemaMigrationPlan` in MailStoreContainer.swift or CachedModels.swift
      - adding iCloud sync or NSFileCoordinator to the store container
      - treating a schema change as requiring a migration plan instead of accepting a cache nuke
    see:
      - .memory/decisions/Herald Sync Model.md
      - HeraldKit/Sources/HeraldKit/Sync/MailStoreContainer.swift
  - id: C3
    text: Never let a SwiftUI view or MailViewModel touch a @Model object directly — views and view-models consume only Sendable value DTOs; all @Model access belongs in MailStore (@ModelActor).
    rationale: A faulted @Model read inside a SwiftUI body crashes uncatchably mid-layout; the DTO boundary makes that class of crash structurally impossible.
    violations:
      - adding @Query or @Model properties to a SwiftUI view
      - passing a @Model object (CachedMessage, CachedConversation, etc.) as a parameter to a view or MailViewModel method
      - "performing a #Predicate query outside of MailStore"
    see:
      - .memory/architecture/Herald Architecture.md
      - Herald/App/MailViewModel.swift
  - id: C4
    text: Never store tokens, OAuth client registrations, or any credential in UserDefaults, logs, memory notes, chat, or source files — they go in the login Keychain via KeychainStore.
    rationale: Credentials in any other location are either logged, synced, or committed; Keychain items are ACL-locked to Herald's signature and never leave the machine.
    violations:
      - writing an access or refresh token to UserDefaults
      - logging a token value (even partially) via os.Logger or print()
      - pasting a credential into a memory note or chat to share context
    see:
      - .memory/conventions/Herald Error Handling and Security Rules.md
      - HeraldKit/Sources/HeraldKit/Security/KeychainStore.swift
  - id: C5
    text: Never push to the remote repository without explicit approval from the owner in the current session.
    rationale: Herald's release pipeline (notarization, Sparkle signing, appcast push) is owner-only and irreversible; an unauthorized push can trigger CI or expose a work-in-progress build to the public feed.
    violations:
      - running `git push` at the end of a task without being explicitly asked
      - pushing as part of a release step that was not directly authorized in this session
      - using `git push --force` on any branch
    see:
      - CLAUDE.md
      - README.md
  - id: C6
    text: Never build with default-MainActor isolation disabled in HeraldKit or Herald, and never place the swift-openapi-generator plugin or its output inside a target that has SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
    rationale: "The isolation split between HeraldAPI (no default isolation) and HeraldKit/Herald (MainActor) is load-bearing: collapsing it causes unfixable Hashable/Sendable conformance failures in the generated multipart types under Swift 6.4."
    violations:
      - moving the openapi-generator plugin into HeraldKit's target in project.yml
      - adding SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor to the HeraldAPI target
      - removing SWIFT_DEFAULT_ACTOR_ISOLATION from HeraldKit or the Herald app target
    see:
      - .memory/decisions/Generated API Client Lives in Nonisolated HeraldAPI Target.md
      - project.yml
guardrails:
  - Search .memory/ (via Memophant MCP search_memories) before assuming any architectural fact; the notes are the authoritative record of every gotcha, decision, and workaround.
  - Edit an existing memory note (edit_memory) rather than creating a near-duplicate; search first.
  - "File memory notes under exactly one of six folders: architecture/, conventions/, decisions/, operations/, project/, roadmap/ — never the .memory/ root."
  - Pass source_paths when writing a memory note grounded in specific source files so Memory Health can detect drift.
  - Store agent-generated artifacts (plans, reports, briefs) in documents/ (exact lowercase) via write_tier_file(tier:'documents') — never in docs/ and never in a case variant like Documents/.
  - Use project.yml as the single source of truth for the Xcode project; regenerate with xcodegen after any structural change; never hand-edit Herald.xcodeproj/.
  - Build with ./scripts/build-detached.sh for integration verification; do not rely on Xcode GUI builds to validate CI-relevant changes.
  - "Loggers are file-scope `private nonisolated let logger = Logger(subsystem: 'com.wizemann.herald', category: ...)` — not inside types, not plain `let`, not `print()`."
  - New UI must read spacing, radius, typography, and status/folder colors from MailTheme tokens — no raw literals where a token fits.
  - Every framework completion handler that may fire off-main must be written as `{ @Sendable args in Task { @MainActor in … } }` to avoid EXC_BREAKPOINT under default-MainActor isolation.
  - A type behind a synchronous nonisolated protocol serializes shared mutable state with OSAllocatedUnfairLock, not by becoming an actor.
  - New fields on cache-blob DTOs (Attachment, DraftAttachment, MailboxAddress, SignatureSnapshot) require a total init(from:) with explicit CodingKeys and a sensible default, plus a CacheIntegrityTests round-trip case.
  - "Tests must discriminate: each test names what broken behavior it would catch. Checkbox tests that only re-assert obvious behavior are removed in audit."
  - Network is faked at URLProtocol level (FakeServerProtocol); no timing-dependent tests — poll with early exit, never sleep-then-assert.
  - After refreshing the vendored OpenAPI spec, run scripts/vendor-openapi.py to rewrite OAS 3.1 nullable syntax before regenerating; a compile break in HeraldKit's wrapper is the intended signal.
  - Upstream (HQBase server) changes go as small, independent PRs to the HQBase repo; this repo is the client only.
  - When writing about Herald's relationship to HQBase in any user-visible text, use 'compatible with HQBase' and include the not-affiliated disclaimer — never imply an official relationship.
non_goals:
  - Supporting any mail protocol other than HQBase Mail API v1 (no IMAP, SMTP, EWS, or other providers).
  - iCloud sync, CloudKit, or multi-device store replication — the server is the system of record and the local store is a rebuildable cache.
  - Versioned schema migration for the SwiftData store — recovery is always delete-and-re-sync.
  - A tabbed editor or multi-document interface — standards §06 is N/A.
  - Being a general-purpose note-taking, task-tracking, or project-management tool.
updated: 2026-09-27
---
