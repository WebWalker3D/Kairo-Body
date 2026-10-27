# Kairo Body reliability assessment and overhaul

Scope: the complete public iPad app, baseline `4b7cedf`, with independent interface, lifecycle and final code reviews. The reported interaction was a question spoken to the Dot while the iPad stayed on a thinking state. Navigation alone was not the failure.

## Findings and repairs

| Area | Defect or gap | Repair and evidence |
| --- | --- | --- |
| Shared conversation | First refresh invalidated its own poll loop; subsequent completion was never read | Bind owner before loop generation; real-client active-to-completed, timeout, 304, foreground and owner-change tests |
| Response feedback | Main stage hid request phases and only showed generic thinking | Shared response panel shows reported work, elapsed time, permission pauses and settled answers; respects shared-preview setting |
| Permission waits | Dot requests could pause without a usable iPad review path | Existing observer and permission APIs, full request review, explicit once-only Allow/Deny; no automatic or persistent grants |
| Submission recovery | Pending work could be replaced, reset, or discarded after uncertain submission | Preserve original message/key, prevent competing submissions, resume the same job, retain uncertain cancellation |
| Cancellation | Late preparation could submit after Stop; repeated local Stop could become inert | Generation fencing before submission and after awaits; local playback stops independently of remote cancellation deduplication |
| Voice | Wake capture never rearmed after its first request; playback state was unwired | Composition root observes request and audio busy states; repeated real-client synthetic voice flows cover success and failure |
| Private room | Late results could return after stop/unpair; background lost the job handle | Owner/generation fences; pause clears presentation but preserves memory-only recovery; authorization loss clears private state |
| Pairing | Late redemption could save a forgotten proof | Fence the credential write before mutation; delayed-response regression |
| Credential replacement | Delete-before-add could destroy a working token, while setup reported success | Checked update/add; failed writes remain visible and preserve the existing item |
| Shared vision | Global conversation answer remained under an unrelated replacement image | Image-generation-bound answer storage and late-result rejection |
| Private input | Oversized text disappeared before validation | Validate before consuming; show the limit and preserve unsent text |
| Invitations | Source session was discarded; concurrent sends could lose the handoff | Carry source identity and reserve the invitation handoff |
| Surface output | Busy output was silently dropped; failed receipts were forgotten | Explain refusal; bounded receipt retry and explicit reconciliation, without repeating display/playback |
| Settings | Reset could discard a pending request and did not reset configured Echo | Restrict and accurately label new iPad-local conversations |
| Accessibility | Ring contact exposed no semantic activation | Accessible contact action through the existing sensory/contact path |

The original Metal particle body, shared surface routing, capability catalogue, rest projection, mounted-display acknowledgments, privacy toggle, sensor opt-ins, and server authorization boundaries remain in place. No new synthetic affect or estimated answer-completion percentage is introduced.

## Validation history

- `ca58cad` / Actions `40428867040`: simulator regressions reproduced the original feed, submission, privacy, image and credential failures; the old navigation journey still passed.
- `8465178` / Actions `40431633697`: those repairs passed. Only the deliberately unimplemented approval client and the unrepaired surface recovery cases failed (22 assertions). All 167 tests executed; no Keychain fixture skip remained.
- `fb69abb` / Actions `40434287705`: all four final-review regressions failed for the intended behavior (7 assertions); the other 174 unit tests passed, including the repaired approval and surface clients. Final-review regressions cover exhausted submission recovery, repeated Stop, distinct shared activity behind a local error, and invitation reservation. The release evidence will name the final complete commit and CI run rather than imply intermediate candidates were qualified.
- Three intermediate simulator builds caught test compilation mistakes. They were corrected; they are not counted as passing validation.
- The first unit-hosted response screenshot capture returned blank images. The capture harness now uses a scene-attached window and rejects blank output; original blank files are not visual acceptance evidence.

Tests replace only external HTTP/storage boundaries with synthetic fixtures. They do not contact production, grant live permissions, replay messages, or claim physical-device acceptance.

## Integration findings outside the app

Read-only checks of the running service found a recent Dot self-inspection question paused at an unresolved permission request, rather than continuing inference. The existing permission gate waits for a decision. A separate reported Discord job ended after malformed tool-call output was rejected. App feedback must distinguish both states from ordinary generation.

The app now exposes existing once-only decisions for explicit user review. It does not change server tool authorization or globally exempt introspection tools. The precise server-side offered-tool/preauthorization mismatch requires its own backend correction; no production code, service, routing, schedule or live permission was changed during this app overhaul.

## Remaining acceptance boundaries

- This is an in-place replacement build, not a remote installation. Use the same app/signing identity and install over the current app; do not uninstall first. Bundle, Keychain and UserDefaults identifiers are unchanged.
- Real iPad microphone/camera permissions, audio interruptions, Bluetooth routes, thermal/frame-rate behavior, VoiceOver and large text need physical-device acceptance. Simulator success cannot certify them.
- Private request recovery and unconfirmed surface receipts are memory-only. App termination cannot reconstruct private prompts or prove a lost delivery receipt. Ordinary shared messages remain durable.
- Network loss, server generation failures and server authorization waits remain possible. They must be visible and recoverable; a claim of zero possible bugs or guaranteed instant model answers would be false.
