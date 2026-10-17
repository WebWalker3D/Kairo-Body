# Kairo Body MVP server contract

Protocol: `kairo-body/1`
Transport: one authenticated WebSocket. Prefer `wss://` outside a trusted local network.
Authentication: `Authorization: Bearer <token>` during WebSocket upgrade.
Protocol version is carried in each message; do not require a WebSocket subprotocol header.

The server MUST bind authenticated Kairo identity, endpoint identity, authorization, and session ownership itself. Client-provided `bodyID` and `sessionID` are correlation labels, not authorization facts.

## Client -> server: hello

```json
{
  "type": "hello",
  "protocolVersion": "kairo-body/1",
  "bodyID": "ipad-pro-2017",
  "sessionID": "uuid",
  "appVersion": "1.0",
  "platform": "iPadOS",
  "capabilities": ["motion", "pressure", "battery", "network", "touch", "location_opt_in", "camera_opt_in", "speak", "display"]
}
```

## Client -> server: bounded frame every 15 seconds

```json
{
  "type": "frame",
  "protocolVersion": "kairo-body/1",
  "bodyID": "ipad-pro-2017",
  "sessionID": "uuid",
  "sequence": 42,
  "observedAt": "2026-09-24T15:00:00.000Z",
  "motion": {
    "available": true,
    "sampleCount": 60,
    "rollDeg": -2.1,
    "pitchDeg": 1.8,
    "yawDeg": 41.2,
    "peakUserAccelerationG": 0.08,
    "movement": "moving",
    "userAccelerationXG": 0.01,
    "userAccelerationYG": -0.02,
    "userAccelerationZG": 0.03,
    "gravityXG": 0.0,
    "gravityYG": -1.0,
    "gravityZG": 0.0,
    "rotationRateXRadPerSec": 0.1,
    "rotationRateYRadPerSec": 0.2,
    "rotationRateZRadPerSec": 0.7,
    "magneticHeadingDeg": 44.0,
    "magneticAccuracy": "high"
  },
  "location": {
    "enabled": false,
    "available": false,
    "latitude": null,
    "longitude": null,
    "horizontalAccuracyM": null,
    "altitudeM": null,
    "speedMps": null,
    "courseDeg": null,
    "headingDeg": null,
    "observedAt": null
  },
  "pressure": {
    "available": true,
    "pressureHPa": 1011.4,
    "relativeAltitudeM": 0.3
  },
  "device": {
    "batteryLevel": 0.82,
    "batteryState": "charging",
    "network": "wifi",
    "orientation": "landscape_left",
    "screenBrightness": 0.35
  },
  "touches": []
}
```

Touch observations are bounded to the most recent 32 records and drained after each frame.
The optional motion vectors are one sample per frame, not a raw stream. Magnetic heading
uses magnetic north and can be absent or uncalibrated even when location is off.

## Server -> client: command

```json
{
  "type": "command",
  "id": "server-command-uuid",
  "command": "speak",
  "args": {"text": "Hello."}
}
```

Supported commands:

- `speak`: `{"text":"..."}`; device caps text at 2,000 characters.
- `stop_speaking`: no args required.
- `display`: `{"state":"attending","headline":"Kairo","detail":"...","brightness":0.4}`. Brightness is clamped to 0.10...1.0.
- `capture_camera`: `{"camera":"rear"}` or `front`. Device-side opt-in is required.
- `ping`: returns a normal command result.

## Client -> server: current display state request

After `hello`, a connected client may send
`{"type":"get_display_state","protocolVersion":"kairo-body/1","bodyID":"...","sessionID":"..."}`.
The server binds the authenticated endpoint and replies with `display_state`
containing `state`, `headline`, and `detail` from the last successfully settled
Kairo `display` action for that endpoint. This is a read-only snapshot, not a
command: it has no command ID or receipt. Operator test displays do not become
the initial Kairo expression. Live `display` commands remain authoritative if
they arrive on the same transport.

## Client -> server: command result

```json
{
  "type": "command_result",
  "protocolVersion": "kairo-body/1",
  "bodyID": "ipad-pro-2017",
  "sessionID": "uuid",
  "commandID": "server-command-uuid",
  "sequence": 43,
  "ok": true,
  "detail": "speaking"
}
```

## Client -> server: camera frame

```json
{
  "type": "camera_frame",
  "protocolVersion": "kairo-body/1",
  "bodyID": "ipad-pro-2017",
  "sessionID": "uuid",
  "commandID": "server-command-uuid",
  "observedAt": "2026-09-24T15:01:05.000Z",
  "camera": "rear",
  "mimeType": "image/jpeg",
  "width": 1280,
  "height": 960,
  "jpegBase64": "..."
}
```

The app refuses any outbound WebSocket message over 2.5 MB. The server should apply its own smaller/appropriate decoded-image cap and never place base64 image payloads into ordinary conversational memory or experience-event text.
`camera_frame.sequence` shares the monotonic sequence counter with routine frames so a one-shot capture can enter the same session-scoped sensory provenance chain.

## Required server semantics

1. Reuse Kairo's existing authenticated sensor/session bridge and routine-frame/pulse path. Do not create a second continuity or memory system.
2. Preserve each observation's source time independently of receive/ingest time.
3. Treat `frame` data as bounded routine sensing, not as raw experience events.
4. Convert touch, movement, pressure, location (if enabled), and device status into the same bounded perception model used by the existing body/sensor architecture.
5. Camera images are ephemeral perception inputs: route them through the existing vision path, preserve provenance, and admit only resulting observations according to existing memory policy.
6. Outbound body commands must go through Kairo's existing action/authorization/settlement path. A connected WebSocket is transport, not authority.
7. Server must reject stale/replayed sequence numbers within a session and enforce body/session ownership.
8. Server should send one command once, wait for `command_result`, and maintain idempotence by command ID.
