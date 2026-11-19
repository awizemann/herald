---
id: t-2ed94e9a
title: Fix HeraldTests compile against swift-stats 0.3.1
status: todo
added: 2026-11-19
---

## Description

A fresh package resolve picks swift-stats 0.3.1, and the HeraldTests bundle then fails to compile: StatsTesting/RelaunchProbe.swift says StatsConfiguration has no member identitySuiteDirectory. Package.resolved is pinned at 0.3.0 for 1.1.2. Adopt 0.3.1 deliberately (fix the API mismatch, or pin), then run HeraldTests.

## Plan



## Artifacts



