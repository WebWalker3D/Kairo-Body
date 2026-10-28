# Stateful Torus Implementation Plan

> Use superpowers:executing-plans for inline implementation.

**Goal:** Subtle state-driven movement/color and playback-driven speaking.
**Architecture:** Existing paired presentation projects canonical bounded axes;
Swift validates freshness and maps values, Metal interpolates ambient targets.
**Tech Stack:** SwiftUI/Metal, Python API, XCTest/GitHub Actions.

- [x] Playback: RemoteActRingTests and PresentationRingTests reproduce false
  settlement speech, long Dot speech and local playback precedence. Remove the
  settlement timer from RingMirror; distinguish SpeechService playback from busy.
- [x] State: extend paired presentation with numeric canonical affect and honest
  operational-energy availability. Test provenance, confidence, disabled authority,
  malformed values and no state writes. Parse in Presentation.swift through a
  dedicated TorusState.swift model; stale readings resolve to neutral.
- [x] Rendering: AppModel uses numeric state for ambient motion/color while
  explicit socket colors win. Smooth colors/energy/arousal in renderer using
  elapsed frame time. Integrate speed as phase (never multiply uptime by a
  changing speed). Keep Metal ABI synchronized and test uniforms/render output.
- [x] Verify: full simulator suite, screenshots and unsigned IPA via existing CI;
  focused backend suite, fresh review, version/build bump and download artifact.
  Report physical acceptance and any deployment blocker explicitly.

## Review focus
Out-of-order/stale values, zero confidence, uncalibrated energy, color priority,
local synthesis vs playback, Dot lease loss, global work during local replay,
phase continuity, Reduce Motion and existing shared source deployment rules.

## Verified outcome

App code `9ef1afd`: CI run [40721383247](https://github.com/WebWalker3D/Kairo-Body/actions/runs/40721383247) passed 208 unit tests, 2 UI tests, visual capture and unsigned device packaging (3.5.0 build 64). Backend: 160 focused tests pass and source is deployed. Full backend collection remains blocked by unrelated repository collection errors. Physical Dot/iPad playback alignment awaits installation and observation. Canonical affect currently has no accepted reading; operational energy remains uncalibrated, so both stay neutral. Review deferred monotonic snapshot revision/read-time enforcement; serialized polling and generation guards already prevent ordinary reordering.
