# Herald

**Herald is a native macOS mail client for [HQBase](https://github.com/HQBase/hqbase)** — a fast,
keyboard-friendly, three-pane reader and composer for self-hosters who run their own HQBase
instance. Swift 6, SwiftUI, SwiftData, Sparkle updates, AGPL-3.0.

- Download: the latest notarized build is on the
  [Releases page](https://github.com/awizemann/herald/releases); the app updates itself afterwards.
- Source: this repository. `project.yml` is the source of truth; `Herald.xcodeproj` is generated.
- Status: early but dogfooded daily against a real HQBase ≥ 1.1.0 instance — see the
  [README](https://github.com/awizemann/herald#status) for the current feature list and
  [CHANGELOG.md](https://github.com/awizemann/herald/blob/main/CHANGELOG.md) for what shipped when.

## Start here

| If you want to… | Read |
|---|---|
| Build and run Herald from source | [Getting Started](Getting-Started) |
| Understand how the pieces fit together | [Architecture Overview](Architecture-Overview) |
| Know how sign-in and token storage work | [Authentication and Accounts](Authentication-and-Accounts) |
| See how mail is fetched and cached | [Sync and Storage](Sync-and-Storage) |
| Learn how the HQBase API is called | [API Client and Network](API-Client-and-Network) |
| Change the composer, drafts, or attachments | [Compose and Drafts](Compose-and-Drafts) |
| Touch notifications, the Dock badge, or search | [Notifications and Search](Notifications-and-Search) |
| Add UI that matches the rest of the app | [UI and Design System](UI-and-Design-System) |
| Write or run tests | [Testing and Quality](Testing-and-Quality) |
| Cut a release | [Release and Updates](Release-and-Updates) |

## The three rules that shape every page

1. **The server is the system of record.** The local SwiftData store is a rebuildable cache:
   no schema migrations, recovery is delete-and-resync. ([Sync and Storage](Sync-and-Storage))
2. **Views never touch a `@Model`.** Everything crosses from `HeraldKit` into the UI as frozen,
   `Sendable` value types. ([Architecture Overview](Architecture-Overview))
3. **Swift 6 strict concurrency, `@MainActor` by default.** Background work lives in actors;
   anything that must be callable from anywhere is explicitly `nonisolated`.

## Where the deeper record lives

This wiki is the readable guide. The authoritative design record — architecture notes,
conventions, decisions, and every HQBase server-contract gotcha found along the way — lives in
the repo's `.memory/` folder, managed by [Memophant](https://memophant.co). When a wiki page and a
memory note disagree, the memory note wins and the wiki page needs fixing
(see [Wiki Maintenance](Wiki-Maintenance)).

## Contributing

Herald is the client only. Server-side changes it needs go upstream to HQBase as small, separate
pull requests (the origin story is [HQBase/hqbase#11](https://github.com/HQBase/hqbase/issues/11)).
Bug reports and PRs for the client are welcome on this repo's
[issue tracker](https://github.com/awizemann/herald/issues).

---
_Last updated: 2026-08-19 — rewritten as a real landing page_
