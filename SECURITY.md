# Security policy

Camera Bridge handles camera credentials, a HomeKit pairing identity and live video of people's homes, so security reports
are taken seriously.

## Reporting a vulnerability

**Email <security@camera-bridge.app>.** Please do not open a public issue or pull request for a vulnerability.

Include what you found, the Camera Bridge version (Camera Bridge ▸ About), macOS version, steps to reproduce, and what an
attacker could do with it. If you need to share sensitive details, say so in a first message and we will agree on a safe way.
Do not include real camera passwords or video of other people.

You can expect an acknowledgement within 5 business days and a first assessment within 14 days. Fixes for confirmed issues
ship in a normal update (Sparkle delivers it); you will be told when it is out and credited if you wish. Please give a
reasonable period to fix a problem before you publish it. 90 days is a good default.

## Scope

In scope: the Camera Bridge app and engine in this repository, including its HomeKit Accessory Protocol server (pairing,
sessions, HomeKit Data Stream), camera credential handling, the local webhook server, the diagnostics export and redaction,
the update mechanism and release signing, and the build scripts.

Out of scope: vulnerabilities in cameras or their firmware, in Apple's Home app, hubs or operating systems, in third-party
dependencies (report those upstream; tell us if Camera Bridge is affected), social engineering, and findings that need a
Mac that is already compromised or physical access to an unlocked Mac.

## Supported versions

Only the latest release receives security fixes. The app updates itself.

## What Camera Bridge does with secrets

- Camera passwords and the HomeKit pairing keys are stored in the login keychain, never in the configuration file or logs.
  Logs and the diagnostics export are redacted (URL user info, password-like parameters).
- Camera Bridge only talks to the cameras on your network and to the paired Home hub; the only connections to the internet are
  the update check and the camera-profile list, plus anonymous setup reports if you turn them on.
- Releases are signed with a Developer ID, notarized by Apple, and updates are verified with an EdDSA signature before they
  are installed.
