# Echo Dot integration

Kairo Body uses the existing Agent API for jobs, transcript, token events and
committed StateFrame. It follows only the Echo session explicitly configured in
the app, filters exact Echo surface metadata, and never speaks Dot replies on
the iPad. Configure that session in Settings; public builds carry no personal
session ID. Existing saved settings and Keychain entries retain their identifiers.

An Agent-authenticated `/ws/body` connection observes transient Dot activity and
requests replay. The sensory bearer and `kairo-body/1` socket keep their own scope.
The observer advertises no speech, camera or haptic actuator. Following and replay
must not create jobs or mutate memory. The observer follows only in foreground.

Replay requires fresh available audio, no pending request, and a resting controller
phase (`idle` or `listening`). Disconnected, expired, thinking, speaking, replaying
or speech-detected states disable it.

Simulator tests cover session binding, settled replies, activity expiry and
reconnection. Physical acceptance requires a real Dot utterance, a matching iPad
transcript, one Dot playback and no duplicate iPad playback. Hosted tests cannot
prove physical microphone, camera, location or speaker behavior.

App builds do not deploy or configure the server or Dot controller.
