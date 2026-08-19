---
created: 2026-08-19
updated: 2026-08-19
---

# Getting Started

## Requirements

- macOS 15 (Sequoia) or later, Apple silicon
- Xcode 27 or later (the toolchain the CI and releases use)
- `xcodegen` 2.45+ (for generating the Xcode project)
- An HQBase instance running 1.1.0 or later with OAuth bearer support

## Build from source

Install `xcodegen` via Homebrew:

```sh
brew install xcodegen
```

Clone the repo, generate the project, and open it:

```sh
git clone https://github.com/awizemann/herald.git
cd herald
xcodegen generate
open Herald.xcodeproj
```

Then build and run the Herald scheme in Xcode.

## Build from the command line

To build in an isolated DerivedData directory and launch a dev copy:

```sh
./scripts/build-detached.sh
```

It keeps a private DerivedData folder and quits only its own previous instance, so it never touches the released Herald you may also be running.

## Project structure

`project.yml` is the source of truth for all build configuration; `Herald.xcodeproj` is generated and should not be edited directly. Run `xcodegen generate` after any change to `project.yml`.

The layout is:

- `HeraldKit/` — Swift Package with all logic (auth, API, sync/cache, compose, notifications); `HeraldAPI` inside it is the generated OpenAPI client
- `Herald/` — the SwiftUI app: app coordination, views, compose window, design tokens, analytics
- `HeraldTests/`, `HeraldKit/Tests/` — test suites
- `scripts/` — build and release helpers
- `.memory/` — project decisions, architecture, conventions (read these for deep context)
- `CHANGELOG.md` — release notes, also consumed by the release script

## First run

1. Launch Herald
2. Click "Sign in" and authorize with your HQBase instance
3. Herald lists your mailboxes and starts syncing; the local cache makes later launches instant
4. Start reading and composing — more accounts can be added from the sidebar switcher

Debug builds use their own Keychain namespace and cache, so a dev copy runs side by side with the
released app without sharing a sign-in.

## Verify your setup

Check that:

- Xcode 27 is selected: `xcodebuild -version`
- You can generate the project: `xcodegen generate` (should update timestamps on `.pbxproj`)
- The app builds: `./scripts/build-detached.sh` (should produce a runnable app)

---
_Last updated: 2026-08-19 — build and setup; fact-checked against the code for v0.3.0_