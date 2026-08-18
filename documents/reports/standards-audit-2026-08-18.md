# Herald — Centralized Standards Audit (2026-08-18)

Audited `Herald/**` + `HeraldKit/Sources/**` (production only; tests, scripts, build artifacts, `#Preview` excluded) against the 11 centralized standards at `/Users/awizemann/Developer/_standards/`. Method: 3 parallel discovery agents (code-quality/conventions, storage/security, design/UI), findings reconciled against Herald's own `.memory/` conventions to separate real violations from sanctioned architectural deviations.

**Bottom line:** Herald is in strong shape. Zero Critical, zero High-risk *correctness* issues. The one systemic gap is **design tokens** — `MailTheme` has no spacing/radius/typography/animation scales, so ~60 raw spacing literals live across the views. Everything else is a handful of near-threshold cleanups or deliberate, documented architecture exceptions.

---

## 1. Summary table

| Category | Standard | Real violations | Severity |
|---|---|---:|---|
| Missing token scales in `MailTheme` (spacing/radius/typography/animation) | 05, 06 | 4 scales absent | **High** |
| Hardcoded spacing/padding literals | 05 | ~60 | **High** |
| Oversized files (`MailStore` 1254, `MailViewModel` 1183 — limit 1000) | 04 | 2 | Medium |
| `NSLock` where an actor is preferred (`AccountStore`) | 04 | 1 | Medium |
| Bare `try? decode` without explanatory comment | 04, 02 | 4 | Medium |
| Sparkle `ObservableObject`/`@Published` + `import Combine` (justified interop) | 04 | 1 type | Low |
| Hardcoded font-size literals (decorative hero glyphs) | 05 | 2 | Low |
| Hardcoded corner radius / animation literal | 05 | 2 | Low |
| Force-unwrapped constant URL (`DynamicClientRegistration`) | 04 | 1 | Low |
| TOCTOU `fileExists`→`removeItem` (`MailStoreContainer`) | 03 | 1 | Low |
| Swallowed optimistic-revert `try?` (`MailActionService`) | 04 | 1 | Low |

### Compliant / exemplary (no action)
- **No `print()`** in production — logging uniformly via `os.Logger`.
- **No `DispatchQueue`** — fully on Swift Concurrency.
- **No `@Query` in views** — SwiftData centralized in `MailStore`.
- **Colors fully tokenized** — every literal lives in `MailTheme`; consumption sites use semantic/system colors or tokens. Zero hardcoded colors.
- **Accessibility exemplary** — `MailTheme.iconButtonStyle` bundles hit-frame + `.help` + `.accessibilityLabel`; rows combine children with labels/values; decorative glyphs hidden.
- **State hygiene exemplary** — no view exceeds 1 `@State`; shared state flows through `@Observable` view models.
- **Secrets Keychain-isolated** — tokens/registration via `KeychainStore`/`SecretStore`; zero secret writes to UserDefaults or disk.
- **Logger subsystem** — 22 declarations, all the static literal `com.wizemann.herald` (= the app's bundle id; Apple-idiomatic, more correct than the standard's `com.<app>.app`).

### Sanctioned deviations (documented in `.memory/`, NOT defects)
- **No `VersionedSchema`/`SchemaMigrationPlan`; bare `Schema([...])`** — the SwiftData store is a rebuildable cache (server is system of record); incompatible/corrupt store is deleted and re-synced. See `decisions/Herald Sync Model`, `MailStoreContainer.swift:25`.
- **File-scope `private nonisolated let logger`** (not the standard's in-type `private let`/`private static let`) — deliberate Swift 6.2 default-MainActor adaptation; `Logger` is `Sendable`, so this is safe and 100% consistent. See `conventions/Herald Concurrency Rules`.
- **No `NSFileCoordinator`/`FileCoordinatorService`** — non-iCloud app; the store is a private single-writer cache in Application Support. Standard 03's coordinator mandate is scoped to iCloud-library roots.
- **No backup/restore parity** — rebuildable cache; nothing server-independent to back up.
- **Sanctioned `nonisolated(unsafe)` AppKit bridges** (`WindowCloseInterceptor`) — recorded so audits don't "fix" them.

---

## 2. Top files to fix (ranked by violation volume)

| # | File | Issues |
|---|---|---|
| 1 | `Herald/Views/ConversationListView.swift` | ~17 spacing/padding literals (incl. off-grid 5, 1), the lone animation literal (`:26`, already reduce-motion-gated), 8×8 unread dot |
| 2 | `Herald/Compose/ComposeWindow.swift` | ~13 spacing/padding literals |
| 3 | `Herald/Views/ReadingPaneView.swift` | ~10 spacing/padding literals; 7×7 unread dot (drift vs #1's 8×8) |
| 4 | `HeraldKit/Sources/HeraldKit/Sync/MailStore.swift` | 1254 lines (>1000 service limit) |
| 5 | `Herald/App/MailViewModel.swift` | 1183 lines (>1000); 3 `try? await store.…` |
| 6 | `Herald/Views/SidebarView.swift` | ~6 spacing/padding literals |
| 7 | `Herald/Views/SettingsView.swift` | ~4 literals incl. off-grid `spacing: 1` |
| 8 | `HeraldKit/…/Auth/DynamicClientRegistration.swift` | Force-unwrapped URL (`:13`); 2 `try? decode` (`:46`, `:53`) |
| 9 | `Herald/Views/OnboardingView.swift` / `RootView.swift` | Hero-glyph `.font(.system(size: 44/40))` |
| 10 | `HeraldKit/…/Auth/AccountStore.swift` | `NSLock` (`:45`) → prefer actor |

Also: `MailStoreContainer.swift:97-99` (TOCTOU), `AttachmentChip.swift:32` (cornerRadius 6), `OAuthHTTP.swift:90` / `OAuthSession.swift:139` (`try? decode`), `UpdateService.swift:6,153-154` (Sparkle bridge), `MailActionService.swift:28,70,83` (revert `try?`).

---

## 3. Per-standard breakdown

- **01 Architecture** — Compliant. Strict Sendable DTO boundary, views never touch `@Model`, MVVM-ish with `AppEnvironment`. No `@Query` in views.
- **02 SwiftData** — Compliant given the cache model. No `try?` on save/fetch (all `do/catch`). Bare `Schema([...])` / no versioning is a *sanctioned* exception (rebuildable cache), not a gap.
- **03 Storage & Sandboxing** — Compliant. Only real nit: one TOCTOU `fileExists`→`removeItem` (`MailStoreContainer.swift:97-99`, Low). NSFileCoordinator not required (non-iCloud). Attachment saves are atomic, sanitized, quarantined.
- **04 Swift Conventions** — Mostly compliant. Real items: 2 oversized files; `NSLock`→actor; 4 un-commented `try? decode`; 1 constant force-unwrap; Sparkle Combine bridge (justified). No `print`, no `DispatchQueue`.
- **05 Design System** — The weak axis. Colors + accessibility exemplary, but no spacing/radius/typography/animation token scales → ~60 spacing literals + off-grid values + measurable drift (8×8 vs 7×7 dot).
- **06 Editor Patterns** — N/A in spirit (Herald is a mail triage UI, not a tabbed document editor). The transferable rule — token scales + component reuse — is covered by the 05 findings.
- **07 AI Integration** — N/A. Herald ships no AI features.
- **08 Data Integrity** — Compliant by design. Backup/restore parity and migration rollback contracts don't apply to a rebuildable cache; recovery = delete-and-re-sync.
- **09 Performance** — Compliant. State ownership clean (≤1 `@State`/view); blocking work goes off-main via `Task.detached`/actors (per Concurrency Rules); no `Date()` in hot paths (all 6 are semantic timestamps). Only latent perf lever is splitting the 2 oversized files.
- **10 Testing** — Compliant/strong. Swift Testing only, URLProtocol fake server, discriminating-test discipline documented and enforced (`conventions/Herald Testing Conventions`).
- **11 Multiplatform** — N/A. macOS-only, no iOS companion.

---

## 4. Recommendations (prioritized)

**P1 — Design tokens (retires the largest finding class at the source).**
1. Add `MailTheme.Spacing` (4pt grid: xxs…xxxl), `MailTheme.Radius`, `MailTheme.Typography` (incl. a hero-glyph token), and `MailTheme.Animation` (`quick`/`standard`).
2. Migrate the ~60 spacing/padding literals to the scale, resolving off-grid (1, 5, 6, 7) and the 8×8/7×7 unread-dot drift to one token in the process.

**P2 — Structural cleanups.**
3. Split `MailStore.swift` (1254) and `MailViewModel.swift` (1183) under 1000 via `@MainActor enum` helper extraction (per 04 §4).
4. Convert `KeychainAccountStore`'s `NSLock` RMW guard (`AccountStore.swift:45`) to an `actor`.

**P3 — Low-risk hygiene.**
5. Add explanatory comments to the 4 `try? decode` sites (all in `guard let … else` OAuth error paths) or handle the decode branch explicitly.
6. Replace the TOCTOU `fileExists`→`removeItem` (`MailStoreContainer.swift:97-99`) with a commented `try? removeItem`.
7. Log the swallowed optimistic-revert failures (`MailActionService.swift:28,70,83`).
8. Replace the constant force-unwrap (`DynamicClientRegistration.swift:13`) with a documented static or `guard let`.
9. Leave the Sparkle `ObservableObject`/Combine bridge as-is (no `@Observable` equivalent for Sparkle's KVO publisher) — record as a sanctioned interop point.

**Standard-side feedback (for the centralized docs, not Herald):**
- Acknowledge the file-scope `private nonisolated let logger` pattern for default-MainActor Swift 6.2 projects.
- Note that `subsystem = bundle id` (Herald's choice) is the Apple-idiomatic alternative to `com.<app>.app`.
