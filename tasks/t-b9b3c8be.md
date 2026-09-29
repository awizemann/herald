---
id: t-b9b3c8be
title: 1.0: GitHub Pages product site on gh-pages
status: doing
added: 2026-09-28
---

## Description

Phase D (Sonnet). Static site at awizemann.github.io/herald on gh-pages alongside appcast.xml (release.sh only replaces appcast.xml — must keep it). Match app look (MailTheme tokens, bundled fonts), use design/ handoff screenshots after checking them for private data. Local commit on gh-pages worktree only; no push.

## Plan



## Artifacts

- Worktree: /private/tmp/claude-501/-Users-awizemann-Developer-hqbase-mac/65fb99ca-387e-47ef-a506-e0706ada0fc0/scratchpad/herald-pages (local branch gh-pages, from origin/gh-pages ff2d82c)
- Local commit b37123d "site: Herald product page" — NOT pushed. appcast.xml and .nojekyll byte-identical to origin/gh-pages (diff empty).
- Files: index.html, style.css, img/{window,sidebar,thread,compose,settings}.jpg (~416 KB), fonts/ (Geist-Variable.woff2, SourceSerif4Subhead-Semibold.otf, OFL texts; ~360 KB)
- Verified locally (python http.server): desktop light/dark, 375px mobile dark, no horizontal scroll, fonts load.
- To ship: owner reviews, `git -C <worktree> push origin gh-pages`, enable Pages on gh-pages if not yet, then `git worktree remove`.
- Flag: hero/sidebar images show the domains ariwize.com and wizemann.studio (from the handoff mocks).

