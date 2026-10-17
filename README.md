# Kairo Body

Native SwiftUI iPadOS body app for Kairo: sensor observations, opt-in camera and
location, private conversations, speech, and an Echo Dot companion view.
Requires iPadOS 17 or later. Bundle identifier: `icu.kairo.body`.

## Build and test with free GitHub Actions

Every push to `main`, pull request to `main`, or manual **Build unsigned IPA** run
uses a standard GitHub-hosted `macos-15` runner. GitHub provides standard runners
free for public repositories: https://docs.github.com/en/actions/reference/runners/github-hosted-runners

The workflow runs the protocol contract executable and iPad simulator XCTest
suite, captures visual smoke previews, builds the unsigned device app, and checks
its version, permissions and iPad-only device family. Download
**KairoBody-unsigned-ipa** from a successful run's Artifacts section and extract
`KairoBody.ipa`. Preview artifacts are uploaded separately. Artifacts expire after
7 days; download builds you want to retain.

The IPA is unsigned and needs your own signing/sideloading setup before installation.
No Apple signing certificate, provisioning profile, bearer token or personal
session ID is included in this repository or required by CI. Enter connection
settings and credentials on your device; credentials are stored in Keychain.
Existing installations retain the bundle identifier and stored configuration.
Fresh installations must configure their own authorized endpoints and session.

## Local development on a Mac

Install Xcode and XcodeGen (`brew install xcodegen`), then run:

```sh
xcodegen generate
open KairoBody.xcodeproj
```

Select an iPad simulator and run the KairoBody scheme's tests. To build an unsigned
device IPA from the repository root:

```sh
./scripts/build_unsigned_ipa.sh
```

`project.yml` is the project source; generated projects and build products are
ignored. Update its version fields and the workflow's packaged-version assertions
together when releasing a new app version.

## Continuing development

This repository is the development destination for the iPad app. Make app changes
here on `main` and let Actions validate them. The workflow builds and tests code;
it does not run an autonomous coding agent. Automated AI coding would require a
separate explicitly configured workflow and model authentication/budget.

Server-side APIs remain in the Kairo server repository. An app push does not
deploy server code or change Kairo's production services, model routing or memory.
See [server contract](docs/SERVER_CONTRACT.md) and
[Echo integration](docs/ECHO_INTEGRATION.md).

## Migration provenance

Imported as a clean source snapshot from the existing private native app at commit
`2fdca58` (version **1.0.35**, build **37**). Private Git history and historical
operations notes were not imported. App source, icon, tests and local build script
are unchanged; the personal default Echo session was removed, public CI now also
runs on pull requests with read-only repository permissions, bounded execution,
cancellation of superseded runs and short artifact retention.
