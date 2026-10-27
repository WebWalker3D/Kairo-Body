# Lifecycle and delivery baseline audit — 2026-10-26

Reviewed source baseline `4b7cedf` read-only before adding regressions. Source review does not establish the installed iPad version or live server behavior. No live requests or credentials were used.

Strengths: explicit output claims, mounted display acknowledgment, separate owner proof, sensor opt-ins checked again after async work, bounded socket liveness and source timestamps.

## Important findings (proven control-flow defects)

1. **Private content can return after unpair/background.** `PrivateRoomClient.swift:90–98` writes a completed GET response without checking the generation after the await. `stop():52–54` clears content but leaves the session ID. Hold a completed poll, stop, then release it: the old reply returns. Regression must also prove owner changes cannot read an old private job.
2. **Private turns are lost across background and transient failures.** `AppModel.swift:134` calls `privateRoom.stop()`, discarding its only job handle; foreground has no private recovery. `PrivateRoomClient.swift:81–105` uses a new key for every send and has no uncertain-submission reconciliation. A private memory decision/answer cannot be resumed, and retrying an uncertain POST can duplicate work. Preserve owner-bound recovery in memory, never persist plaintext prompts; pause visible content while inactive.
3. **Cancelled pairing can restore a forgotten credential.** `PairingClient.swift:80–81` writes the Keychain before checking the attempt generation/cancellation. A delayed redeem result after Forget can retain pairing across restart. Gate before every credential mutation; inject storage/network for unsigned tests.
4. **Private authorization errors do not clear prior private content.** `PrivateRoomClient.swift:105` only assigns error, leaving reply and session. After one answer, return 403 for the next call: the prior answer remains. Clear sensitive state only for definitive authorization loss, preserve recovery through transient failures.
5. **Voice wake stops permanently after its first request.** `VoiceInputService.swift:291–297` sets `waitingForReply`; its only reset is `responseFinished():80–83`, with no callers. AppModel also never observes request busy transitions or assigns `SpeechService.onPlaybackStateChange`, so typed requests and playback do not pause microphone capture. Wire these centrally and test success, failure and cancellation release.
6. **Surface delivery silently drops overlapping answers and loses result receipts.** `SurfaceDeliveryClient.swift:76` returns while busy; speech delivery returns before playback completes. A second settled answer is neither executed nor receipted. `finish():124–127` forgets active work before result POST succeeds; the seen set prevents recovery. Surface errors have no view consumer. Track truthful delivery outcomes and retry receipts without repeating playback/display execution.
7. **Invitation acceptance loses the source conversation.** `InvitationClient.swift:78–84` returns only text despite retaining sourceSessionID; `AppModel.swift:363–365` sends it into whichever conversation is currently selected. Fixture invitation from a different session should preserve the source binding.

## Limits and declined judgments

- Actual microphone permissions, audio interruptions, camera hardware performance and iPad rendering require hardware acceptance; source review cannot qualify them.
- Surface claim/result server idempotency and expiry semantics require server contract verification; do not implement blind claim or execution replay from this audit.
- Production health, model latency, installed version and remote routing were outside this app-only review and were not inferred from checkout state.

Assessment: fixes required before a reliability release. The private/voice lifecycle gaps are independent of the known shared-feed generation failure.

## Private/pairing repair candidate

The unified RED run `40428867040` reproduced all five private/pairing regression cases (eight assertion failures), as recorded by the coordinator in `/tmp/body-audit-red.log`. The candidate now separates background pause from owner-context removal, fences private async results by generation and owner identity, and retains a pending request only in memory. Known jobs resume by handle; an unconfirmed submission reuses its original body/key. Accepted job handles release the retained prompt. Authorization loss clears all private content. Pairing checks cancellation/generation before writing owner proof.

Seven private/pairing tests now cover the original five cases plus byte-identical ambiguous-submission recovery and preservation through a transient poll failure. The latter two are added coverage; they were not individually executed in the first RED run. No local Swift/Xcode is available; the coordinator's next simulator workflow must qualify GREEN. Recovery intentionally does not survive app termination, and the UI should disclose that limit. AppModel must call `pause()` on foreground loss, `resumePending()` on foreground return, and `stop()` on unpair.
