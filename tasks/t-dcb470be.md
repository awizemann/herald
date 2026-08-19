---
id: t-dcb470be
title: Analytics P2: write-key plumbing (Info.plist, release.sh, verify 3 cases)
status: done
added: 2026-08-18
priority: high
---

## Description

Info.plist: add key HeraldStatsWriteKey = $(APP_STATS_WRITE_KEY). Do NOT add the variable to project.yml or project settings. scripts/release.sh: require env APP_STATS_WRITE_KEY (fail early if unset), pass it to the archive xcodebuild step as a command-line setting (never echo it), after export assert the built app's Info.plist HeraldStatsWriteKey equals the supplied key (not literal $(...)) and that PrivacyInfo.xcprivacy exists in the bundle; regenerate the project with `env -u APP_STATS_WRITE_KEY xcodegen generate`. Verify: (a) grep pbxproj → zero occurrences of the key value / var; (b) dev build → plist value empty; (c) build with a dummy key via temp xcconfig → expanded. Blast radius: Herald/Info.plist, scripts/release.sh, project.yml (only if PrivacyInfo resource wiring needed). Depends on P1 for PrivacyInfo.xcprivacy existing.

## Plan



## Artifacts

Herald/Info.plist (HeraldStatsWriteKey=$(APP_STATS_WRITE_KEY)); scripts/release.sh (env required, temp 0600 xcconfig outside repo instead of argv — xcodebuild echoes argv; env -u for xcodegen; post-export PlistBuddy + PrivacyInfo assertions). Verified: pbxproj 0 occurrences even with var exported; dev build → ""; keyed build → expanded.

