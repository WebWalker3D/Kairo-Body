# Callback safety audit — 2026-10-31

## Cause established on the physical iPad

Thirteen retrieved KairoBody crash reports from October 23–31 share a native
Swift assertion at `CheckedContinuation.resume(throwing:)`, called from
`SessionBoundSocket.sendPing()`. Latest incident: October 31 at 03:44:01 EDT,
version 3.5.0/build 64. Earlier affected builds include 53, 55, 58, 62 and 63.
The server disconnect followed the native crash; it does not explain termination.
Raw device reports and private operational evidence stay outside this public repo.

The ping callback resumed a checked continuation directly for every callback.
The outer liveness guard protected another continuation and could not prevent
this inner assertion. Its replacement consumes one outcome under a lock and
handles cancellation before or after continuation installation. A late native
callback cannot resume the waiter again.

## Reproductions and repair scope

| Boundary | Reproduction | Repair |
|---|---|---|
| Native ping completion | Concurrent duplicate and success/error callback pairs trap | Lock-protected single completion |
| Ping cancellation | Registered callback never fires; canceled task fails to complete | Cancellation consumes the same completion gate |
| Observation receipt | Old send fails after cancellation and sequence reuse | Async callbacks carry local attempt UUIDs |
| Speech startup | `speak(); stop()` in one actor turn still starts synthesis HTTP | Cancellation/generation checked before startup effects |
| Body command | Stop during accepted-event send; old display still applies | Preserve originating transport across awaits and recheck before effects |
| Microphone input | Invalid sample rate or zero channels still reaches installer | Reject unusable formats before framework call; clean up recording activation |

These are distinct failure modes. Only the first is established as the cause of
the retrieved device crashes. Format rejection is a preventive boundary check,
not a claim that another physical-device crash was observed.

## Test evidence

- [Original unguarded ping regression](https://github.com/WebWalker3D/Kairo-Body/actions/runs/41211811281)
  reproduces `SWIFT TASK CONTINUATION MISUSE` in the simulator.
- [Expanded run](https://github.com/WebWalker3D/Kairo-Body/actions/runs/41212464206)
  completed 215 unit tests before manual cancellation during UI execution.
  Ping regressions passed; stale observation and stopped synthesis reproduced.
  Body test initially failed at its unsigned simulator Keychain fixture, corrected
  by injecting a synthetic credential into the existing transport boundary.
  This canceled run is not a full-suite pass.
- [Format regression](https://github.com/WebWalker3D/Kairo-Body/actions/runs/41213454325)
  confirms invalid sample rates/channels reached the original installer.
- [Focused lifecycle run](https://github.com/WebWalker3D/Kairo-Body/actions/runs/41213982871)
  passes observation, speech and microphone repairs; reproduces stopped display
  execution and no-callback ping cancellation. Its 20 tests produced three
  assertions from those two remaining defects.

Final release verification is recorded separately after Actions completes.
The manual callback-safety workflow supplements the release workflow; it does
not build an IPA or certify UI/device behavior.

## Wider audit and limits

Reviewed continuation/cancellation paths in Reliability, BodyClient, location
and observation delivery, shared/one-shot camera, microphone recognition and
speech playback. Shared-camera pending completion is consumed on its serial
queue; quiet-camera finish and timeout share a queue. No second demonstrated
native duplicate-continuation crash was found there. Independent read-only
review checked the transport and audio fixes.

Source findings outside this repair remain explicit:

- BodyActionLifecycle retains command history indefinitely. A bounded design
  must preserve duplicate-command idempotency; this repair does not evict IDs.
- Speech playback does not explicitly release its ducking audio session. A fix
  needs coordinated recording/playback ownership, not blind global deactivation.
- The dormant photo-output path lacks terminal-error/timeout completion. Active
  front-camera paths use quiet capture instead.

Simulator tests do not certify hardware route changes, thermal behavior or
uninterrupted multi-day operation. The original twelve-hour shader clock wrap
only computes a remainder; crash reports identify the ping callback instead.
