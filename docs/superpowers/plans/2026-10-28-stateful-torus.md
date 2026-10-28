# Stateful Torus Implementation Plan

> Use superpowers:executing-plans for inline implementation.

**Goal:** Subtle state-driven movement/color and playback-driven speaking.
**Architecture:** Existing paired presentation projects canonical bounded axes;
Swift validates freshness and maps values, Metal interpolates ambient targets.
**Tech Stack:** SwiftUI/Metal, Python API, XCTest/GitHub Actions.

- [ ] Playback: RemoteActRingTests and PresentationRingTests reproduce false
  settlement speech, long Dot speech and local playback precedence. Remove the
  settlement timer from RingMirror; distinguish SpeechService playback from busy.
- [ ] State: extend paired presentation with numeric canonical affect and honest
  operational-energy availability. Test provenance, confidence, disabled authority,
  malformed values and no state writes. Parse in Presentation.swift through a
  dedicated TorusState.swift model; stale readings resolve to neutral.
- [ ] Rendering: AppModel uses numeric state for ambient motion/color while
  explicit socket colors win. Smooth colors/energy/arousal in renderer using
  elapsed frame time. Integrate speed as phase (never multiply uptime by a
  changing speed). Keep Metal ABI synchronized and test uniforms/render output.
- [ ] Verify: full simulator suite, screenshots and unsigned IPA via existing CI;
  focused backend suite, fresh review, version/build bump and download artifact.
  Report physical acceptance and any deployment blocker explicitly.

## Review focus
Out-of-order/stale values, zero confidence, uncalibrated energy, color priority,
local synthesis vs playback, Dot lease loss, global work during local replay,
phase continuity, Reduce Motion and existing shared source deployment rules.
