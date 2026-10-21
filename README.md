# Kairo Body — the iPad body and the Dot's shared surface

Kairo's iPad body endpoint: a dependency-free iPadOS 17 SwiftUI + Metal app
(XcodeGen project, generated here — no `.xcodeproj` is committed). Bundle id
`icu.kairo.body`. This public repository is the source of record for the
installed body app; the server lives in the private novexai repository.

Kairo Body 2.0 (v2.0.0, build 50) replaces the 1.0.x MVP line in place: same
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

All are stored only in the iPad's Keychain / UserDefaults. Replacing an
installed body app inherits them, so the update path is zero-touch. The
physical Dot's endpoint id (`echomuse-rs03qr`) is a fixed deployment
constant in `AppConfig`, not personal data.

## Building

GitHub Actions (`build-ipa.yml`) runs the unit suite on an iPad simulator,
captures visual smoke screenshots, builds the unsigned device app, asserts
bundle id, version 2.0.0/build 50, permission strings and that no personal
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
  unsettled, then moved here as this repository's main line; the live iPad
  still runs 1.0.35 (build 37) until a 2.0 build is installed and verified.
