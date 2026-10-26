# Kairo Body Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a cinematic native Kairo surface with real connected activity and reliable visible output.
**Architecture:** Retain AppModel and all authenticated clients. Compose existing signals into a responsive presence workspace and present claimed output at root scope. Correct GPU uniform packing, then extend the procedural renderer.
**Tech Stack:** SwiftUI, Metal, XCTest, XcodeGen, GitHub Actions.
**Spec:** docs/superpowers/specs/2026-10-26-body-surface-design.md

## Global Constraints
- iPadOS 17; no new dependencies; main tracking origin/main, no worktrees.
- Preserve icu.kairo.body, Keychain/UserDefaults and sensor opt-ins.
- No public credentials; no speculative online/sleep claims or production writes.

## Review Focus
- Offline/stale state must remain explicitly unavailable.
- Display delivery on non-stage screens must actually appear.
- Rotation, keyboard and long content must not hide controls.
- Reduced motion and GPU packing must preserve usable rendering.
- Backgrounding and private owner authorization must retain existing fences.

### Task 1: GPU contract
Files: Tests/RingChoreographyTests.swift, KairoBody/KairoRingMetalView.swift.
Interface: KairoRingUniformsStorage retains apply/bind and provides twelve inline float4 emitters to Metal.
- [ ] Add regression asserting 304-byte uniform storage and emitter offsets.
- [ ] Run simulator CI and observe regression fail before fixing.
- [ ] Replace Swift Array storage with inline tuple; verify full XCTest suite.

### Task 2: Presence workspace
Files: PresenceStageView.swift, RootShellView.swift, KairoTheme.swift, new PresenceWorkspace.swift, KairoRing.metal.
Interfaces: consume existing AppModel clients; render surface output globally and preserve action handlers.
- [ ] Build responsive landscape/portrait presence with activity deck, recent conversation, capabilities and fast actions.
- [ ] Apply refined typography/materials, orbit shader and Reduced Motion support.
- [ ] Add tests for activity projection and output visibility; verify simulator screenshots in both orientations.

### Task 3: Integrated state and delivery
Files: AppModel.swift, SurfaceDeliveryClient.swift, root overlay, existing platform status parser as needed.
Interfaces: use verified existing read contracts only; preserve job claims/result receipts.
- [ ] Regress display acknowledgement timing and obscuration before making delivery report success only after view acknowledgement.
- [ ] Show confirmed system state with age/failure handling; keep private content scoped.
- [ ] Run all tests and device build, inspect screenshots, request independent final review.

### Task 4: Deliver
- [ ] Update README/version to 3.0.0 build 56, package guards and release notes.
- [ ] Commit/push complete app main; verify CI and download unsigned IPA and previews.
- [ ] Report build link and hardware acceptance limit.

## Execution ledger
User explicitly delegated choices and requested implementation; proceed inline without design or plan approval questions. Main-only instructions override skill worktree default. No novexai source changes are planned. Baseline integration review reads server continuity separately; source documentation alone cannot establish live state.
