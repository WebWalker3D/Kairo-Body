# Kairo Body development

Use this repository as the iPad app source. Work on `main`, tracking `origin/main`;
do not create worktrees or deployment branches. Keep `icu.kairo.body` and existing
Keychain/UserDefaults identifiers stable so updates preserve device configuration.

Read README.md, project.yml and the relevant source/tests before editing.
Use GitHub Actions for simulator XCTest and unsigned device builds when Xcode is
unavailable locally. Confirm the workflow succeeds before claiming a build passes.
Never commit credentials, personal session identifiers, pairing records or signing
material. Public build artifacts must contain no personal provisioning.

Preserve authorization, owner pairing, sensor opt-ins, source timestamps,
reconnection guards and submission idempotency. Keep changes to app behavior
covered by the existing simulator tests. Hardware acceptance requires a real iPad.
Server changes belong in the server repository and require its operating rules;
app CI is not permission to deploy or alter production services.
