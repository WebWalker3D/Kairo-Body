# Body particle stage — retry

User rejected the dashboard direction and explicitly delegated the redesign,
with a specific requirement for ambitious graphics. Native SwiftUI + Metal;
main only; preserve app identity, credentials and every delivery/auth contract.

1. Replace the scrolling stage with a full-screen body and an expandable
   systems panel. Keep an inline conversation composer, real connection state,
   contact observations, invitations and output overlay. UI journey covers
   both orientations, panel open/close, keyboard and shared-preview privacy.
2. Replace the flat annulus with GPU-rendered three-dimensional particles:
   twisted toroidal filaments, depth shading, luminous point sprites, diffuse
   atmosphere and touch deformation. Preserve twelve emitter inputs, committed
   mood, real activity, sleep/fade and Reduce Motion. Bounded 24,000 points at
   30 fps; no textures, external assets, CPU particle loops or dependencies.
3. Remove serif marketing typography, retain system details on demand. Verify
   actual simulator screenshots, full XCTest suite, unsigned device build and
   package identity. Increment build to 57 / 3.1.0. Review code independently.

Review focus: no fabricated live status, no hidden conversation leakage,
modal/output acknowledgment remains truthful, geometry fits both orientations,
GPU ABI remains 304 bytes, touch coordinates remain normalized, sleep dims all
passes, Reduce Motion freezes motion. Real-device performance is not claimed.

Ruling: use direct native implementation as already delegated; no new design
approval gate. The prior visual direction is superseded, not its safety fixes.

## Evidence and review

- Baseline UI journey b75f008 failed as expected: missing Open systems and
  stage composer controls. All 122 existing unit cases had zero failures
  (one existing unsigned-Keychain fixture skip).
- Fresh independent review of ae99cb1 found no GPU ABI or coordinate blocker.
  It found split output selection between stage and transcript, plus Text here
  not requesting a display. Fix pass binds both composers to shared state,
  preserves drafts in memory across navigation, and maps explicit Text here
  to ipad_display through the existing claim/receipt path. Destination is
  captured at submission so changing the menu during a request cannot reroute it.
- GPU qualification renders the real shader to a Metal texture, checks visible
  coverage, time/touch response, fixed-time stability and sleep dimming.
- Ruling: no server deployment or production inference needed; existing public
  app surface protocol supports ipad_display. Physical iPad performance and
  replacement-install acceptance remain hardware checks.
