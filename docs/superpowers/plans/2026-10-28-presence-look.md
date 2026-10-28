# Look within Presence Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans. The user approved direct implementation of the proposed flow.

**Goal:** Preview the front camera, review a photo, attach locally, and send it through Presence's existing conversation.

**Architecture:** A front-only AVFoundation session is reserved through BodyClient so motion detection and remote captures cannot compete. A shared local image draft appears in both composers. ConversationClient uploads the selected image only on Send, binds the description to the resolved conversation session, and preserves durable submission recovery.

**Tech Stack:** Existing SwiftUI, AVFoundation, Observation, UIKit; iPadOS 17, no dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-presence-look-design.md`. User-approved conversation proposal: live preview → capture → review/retake/cancel → attach to Presence → send question and image in the existing conversation. Keep Look navigation as a shortcut into this flow, with no separate question/reply surface.

## Global Constraints

Work on main per AGENTS.md. Preserve bundle and storage identifiers, pairing, permissions, front-only policy, remote-camera opt-in, timestamps and idempotency. No server changes. Camera frames and draft stay local until Send. No personal provisioning.

## Review Focus

- Cancellation/backgrounding must stop the camera and release its reservation.
- Motion sensing and remote capture must not contend with the viewfinder.
- Failed uploads must retain a retryable image and question; pending submissions must retain attachment identity.
- Navigating between Presence and Conversation must preserve the same draft.
- Rotation, denied permission and missing camera must have usable UI; real camera acceptance needs iPad hardware.

### Task 1: Integrated image draft and capture

Files: new SharedImageDraft.swift and SharedCameraSession.swift; LookTogetherView.swift; BodyClient.swift; ConversationClient.swift; AppModel.swift; PresenceStageView.swift; TranscriptView.swift; RootShellView.swift; PresenceWorkspace.swift; Tests/PresenceLookTests.swift; UITests/PresenceJourneyTests.swift.

- [x] Add a UI regression for opening Look from Presence without losing the composer draft and returning via Cancel. Run CI and confirm the missing camera action fails.
- [x] Add transport-boundary tests for local-only selection, sending vision and question in one session, upload failure retention, and durable pending attachment recovery.
- [x] Implement a local SharedImageDraft with identity-checked removal and immutable photo snapshots.
- [x] Implement serialized front camera start/capture/stop, live preview, review/retake/attach and photo-picker review. Reserve BodyClient camera access while preview runs; stop on dismissal/background.
- [x] Add shared attachment controls to both composers; replace Look's separate question/reply with the capture sheet. Send uploads the snapshot through existing uploadVisual and PendingTurn machinery.
- [ ] Run full simulator suite and unsigned device build in GitHub Actions; inspect portrait/landscape screenshot evidence. Update README with actual behavior and hardware limits.
- [ ] Review the full diff and fix material findings; report verified CI and remaining real-device checks.

## Evidence and implementation decisions

- Baseline run 40702070133: all 193 existing unit tests and existing navigation test passed; new Presence camera entry test failed at the missing camera action, as intended.
- Independent review found permission-alert dismissal and delayed motion-start races. Fixed by separating background from inactivity, using a single camera lifecycle task, and invalidating motion startup tickets. Review confirmed the fixes by static inspection.
- Review is shown after camera stop completes, so Retake cannot race the previous capture teardown.
- Local images are in memory only. The existing PendingTurn store persists the description attachment after Send, retaining existing recovery behavior.
- Simulator/device CI and screenshot inspection are the completion gate. Hardware preview, exposure and camera permission acceptance require the physical iPad.
