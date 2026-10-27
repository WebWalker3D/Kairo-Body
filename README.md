# Kairo Body — the iPad body and the Dot's shared surface

Kairo's iPad body endpoint: a dependency-free iPadOS 17 SwiftUI + Metal app
(XcodeGen project, generated here — no `.xcodeproj` is committed). Bundle id
`icu.kairo.body`. This public repository is the source of record for the
installed body app; the server lives in the private novexai repository.

Kairo Body 3.3 (v3.3.0, build 60) replaces the 1.0.x MVP line in place: same
bundle id, same Keychain service/accounts (`icu.kairo.body` bearer-token /
agent-token, `icu.kairo.body.owner` paired-owner-proof), same UserDefaults
identity (`echoSessionID` and friends), endpoint id `ipad-pro-2017`. A
replacement install therefore inherits the stored credentials, owner pairing
and shared Echo session — the setup screen never appears on an updated device.

## What this app is

- The iPad is one body endpoint in Kairo's embodied system: a sensory socket
  (`kairo-body/1` over the memory service) plus Dot-linked surfaces.
  Cognition, memory, review and authorization remain server-side.
- Its centrepiece is the **living ring**: the same twelve-emitter visual
  language as the physical Dot (EchoMuse RS03QR). It mirrors the Dot's
  transient activity stream (phase + output levels), the paired-owner
  presentation (activity phase, committed affect preset, proximity) and this
  body's local acts. It never invents affect: absent signals fall back to
  idle, and a failed read never replaces a committed mood.
- With a shared Echo session configured, typed, spoken and touched requests
  enter the **Dot's own conversation**: the transcript on this iPad is the
  same conversation the Dot is holding, read from the owner-scoped
  all-surfaces feed (`/api/ipad/conversations`, ETag-conditional).

## Surfaces

- **Stage** — living ring, live Dot phase, owner proximity, server display
  commands, invitations, replay/stop quick actions. Touching the ring is a
  contact observation: it is flushed through a sensory frame and then claimed
  through the endpoint/contact body-reflex mode so Kairo can acknowledge the
  touch itself.
- **Conversation** — all-surface transcript (Dot, Discord, phone, iPad) with
  per-turn progress, tools and usage; composer with output destination
  (Kairo decides / silent / text here / speak here), idempotent submission
  with durable recovery.
- **Look together** — one explicitly shared image (front camera or photo
  picker) becomes a server vision observation; its description attachment
  rides with the next question, grounding the Dot's conversation.
- **Private room** — six-digit owner pairing for this exact endpoint;
  owner-private session (`client: ipad_private`) kept out of the shared
  transcript; memory proposals pause the job until an explicit Keep/Dismiss
  on this device.
  **Wake Kairo** is a separate confirmed emergency sleep-wake action. It uses
  the existing paired Agent HTTP path, requires no inference, and distinguishes
  completed receipts from pending, denied and unconfirmed outcomes.
- **Body** — sensory link state, endpoint id, capability availability versus
  permissions, and the last frame Kairo actually ingested.
- **Settings** — appliance preferences, plus credential setup on fresh
  installs.

## Provisioning model (public CI)

Public builds carry **no personal provisioning** — no tokens, no personal
session ids, in source or artifacts (the CI asserts this before packaging).

On a fresh install, setup asks for:

- the **agent token** (Agent Platform bearer) — everything conversational;
- the **body sensory token** — the `/v1/body/ws` socket and pairing redeem;
- the **shared Echo session id** — the conversation the Dot is holding.

All are stored only in the iPad's Keychain / UserDefaults. Setup can be
deferred once ("Not now"); the sheet never reappears unasked — Settings ›
Credential setup is the re-entry path. Replacing an installed body app
inherits everything, so the update path is zero-touch. The physical
Dot's endpoint id (`echomuse-rs03qr`) is a fixed deployment constant in
`AppConfig`, not personal data.

## Building

GitHub Actions (`build-ipa.yml`) runs the unit suite on an iPad simulator,
captures visual smoke screenshots, builds the unsigned device app, asserts
bundle id, version 3.3.0/build 60, permission strings and that no personal
provisioning was baked, then uploads `KairoBody.ipa`.

On a Mac directly:

```bash
scripts/build_unsigned_ipa.sh   # needs XcodeGen; produces KairoBody.ipa
```

Install through SideStore. The bundle id is unchanged, so the update lands
in place on the iPad.

## Machinery that must never regress

- One authenticated body socket at a time (`TransportGate`); bounded 17 s
  frames against the server's 15 s ingest gate; 20 s ping liveness with a
  10 s deadline; heartbeat failure tears the link and re-enters the single
  reconnect ladder.
- Capability reports separate permission from availability
  (`kairo.body_capabilities.v1`); rear camera is always `blocked_by_body`;
  speech busy and obscured display report honestly.
- Command execution uses the `body_action_events_v1` lifecycle: an action is
  `completed` only after real playback finished or the display actually
  changed; camera and location commands report the server's observation id.
- Camera frames are one-shot front-only, ≤1280 px JPEG, and an ingestion
  receipt (`observation_ack`) proves delivery, not just transport.
- `dot_activity` frames (protocol v2) carry a sequence watermark: late
  re-sends cannot extend a lease, expired leases clear state, and a new
  controller epoch is accepted only after expiry. Replay is offered only
  while fresh, idle and `replay_available`.
- A settled answer routed to this iPad is atomically claimed
  (`api/surfaces/{target}/deliveries/{job}/claim`) and receipted; foreground
  loss reports failure so Kairo can choose another surface honestly.
- Outages never erase a conversation or a pending turn: only a confirmed
  401/403 clears owner-private content, and a submitted turn is replayed
  byte-identically under its idempotency key.
- The screensaver/dark stage advances only on genuine quiet: Kairo's actual
  work — on any surface, seen through the Dot stream or `api/platform` —
  keeps the appliance present; a bare heartbeat never does.

## History

- 1.0.x shipped from the private `KairoBodyMVP-build` repository; its
  `docs/SERVER_CONTRACT.md` and `docs/ECHO_INTEGRATION.md` remain the wire
  contract references and still describe the live server faithfully.
- The 2.0 rewrite landed in novexai's `ios/KairoBody` while the design was
  unsettled, then moved here as this repository's main line; the installed device version must be checked on the iPad; repository history
  does not establish which build is currently installed.

## 3.1 — Immersive particle body

The stage fills the screen with 24,000 GPU-rendered particles: 32 flowing
filaments, perspective depth, spectral light and a dispersed outer field.
The twelve Dot emitters, committed mood palette, activity and sleep/fade still
control its expression. Touch deforms the local field while preserving the
existing contact observation. Reduce Motion freezes the procedural clock.

Type directly on the stage, choose the existing output destination, or open
Conversation. The expandable Systems panel holds the shared preview, links,
committed state and reported rest. The shared-preview privacy preference is
respected. The stage fits portrait and landscape without scrolling.

Kairo-selected iPad output now follows `metadata_json.surface_output_target`
from a completed job. Display output appears above any destination and must be
acknowledged by the mounted view before a successful delivery receipt. Sensory
display commands use the same mounted root panel, including state-only commands.
Explicit speech advertises presence before submission. Existing claims,
authorization and durable idempotency are retained.

The Body screen includes a searchable, read-only capability catalogue. Reported
rest comes from a narrow `/api/kairo-state` projection; private dream text is
never retained or displayed. These reads run every 30 seconds only in the
foreground with local owner pairing. Unavailable/stale rest is unknown, not
awake. Enabled capabilities are not claims of authorization or readiness.

Metal's twelve emitter values now use a verified 304-byte inline uniform block,
fixing the former 128-byte Swift Array-reference upload. The particle treatment
keeps the original twelve directional emitter inputs and committed mood palette.
Reduce Motion freezes procedural motion while retaining real state updates.

CI includes the complete unit suite, portrait/landscape navigation screenshots,
and an unsigned device build. Hardware sensor, audio and performance acceptance
still requires installing the replacement IPA on the iPad.


## 3.2 — Response and recovery overhaul

The main stage observes shared questions from the Dot and other owner surfaces,
shows elapsed time and reported work, distinguishes permission waits from
inference, and previews settled answers. This follows the shared-preview privacy
setting. Observing a response never claims delivery or speaks it automatically.

A pending approval can be reviewed in full and allowed once or denied explicitly.
The app never sends an automatic decision, never offers a persistent grant, and
rejects stale, truncated or changed requests. An accepted decision means queued,
not completed. These endpoints retain the server's existing bearer authorization;
local pairing is an additional app guard, not a stronger server permission model.

The shared feed now continues after its first refresh. Submission cancellation,
relaunch recovery, private foreground recovery, voice rearming, image-answer
binding and checked credential replacement have regression coverage. Private
recovery remains memory-only: app termination clears the local private recovery
handle. Ordinary shared requests retain their existing durable idempotency keys.

Install the replacement IPA over the existing app using the same signing identity.
The bundle and Keychain/UserDefaults identifiers are unchanged. Do not uninstall
first if you want to retain application settings.

Simulator tests use synthetic transport responses, including complete question to
settled-answer flows. They do not certify real microphone/camera behavior, actual
model latency, or performance on the physical iPad. See the assessment for evidence
and remaining operational limits.

## 3.3 — Touch that arrives, a calmer shell

Touching the ring now reaches Kairo. The reflex claim used to name a contact
id (`ipad:<session>:<n>`) the sensory frame never carried (`stage-<n>`), so the
server always answered "contact not observed" and every touch ended in "That
touch did not reach Kairo in time". Stage touches now carry one per-launch
unique id from the frame through the claim, and the claim waits for the
frame's `observation_ack` — the server publishes a contact only after storing
it. While a touch is in flight the ring says so; a second touch meanwhile stays
a sensory observation (the server allows one reflex per 15 s).

The app uses Observation (`@Observable`) instead of one model that re-published
every child's change: views redraw only for the state they read. Time-relative
views read an explicit one-second `model.clock`. The stage's Metal field pauses
while the screensaver covers it.

The rail carries Presence, Conversation and Look, plus Systems: a panel, from
any screen, with Private, Body and Settings tiles above the Kairo-wide state.
Small type is larger throughout.

The Dot observer sends its bearer in `Authorization` with the bare `novexai`
subprotocol rather than as a subprotocol value; this needs the agent API from
novexai `3c420b67` or later. A missing Keychain credential is reported as
`CredentialUnavailable` (transient), never as a synthetic 401, and a locked
Keychain answers with the last value read rather than "absent".
