---
title: Herald Project Overview
type: note
permalink: hqbase-mac/project/herald-project-overview
tags:
- project
- hqbase
---

Herald (working codename) is a native macOS email client for HQBase (https://hqbase.io, AGPL,
Cloudflare Workers shared-mailbox workspace). Repo: ~/Developer/hqbase-mac. It talks ONLY to
the versioned public Mail API (`/api/v1`, OpenAPI at `{origin}/api/v1/openapi.json`) with OAuth
2.1 PKCE bearer tokens. Upstream tracking issue: https://github.com/HQBase/hqbase/issues/11
(owner: bermanto). Intent: build in the open, contribute back.

## Observations
- [fact] App codename "Herald"; bundle id com.wizemann.herald; upstream trademark policy forbids naming an unofficial client "HQBase" — say "compatible with HQBase", rename only if upstream adopts it #naming
- [fact] Server = HQBase >= 1.1.0 (public Mail API v1 + OAuth bearer on /api/v1 shipped in upstream PR #12 for issue #11) #server
- [constraint] Server is self-hosted per customer, so an Account = an origin URL + a dynamically-registered OAuth client id; multi-account = multi-origin #accounts
- [fact] Sibling repo ~/Developer/hqbase is a fork of upstream (remote `upstream` added) used only for reading server code / preparing upstream PRs #repos
- [todo] Follow-up upstream asks (offered to author): cursor pagination on GET /api/v1/messages and an updatedSince/changes cursor for delta sync #upstream

## Relations
- relates_to [[HQBase Mail API v1 Contract]]
- relates_to [[Herald Architecture]]
