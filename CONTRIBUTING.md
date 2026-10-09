# Contributing to Camera Bridge

Thank you for helping. Camera Bridge is free for personal and noncommercial use, and the source is available under the
[PolyForm Noncommercial License 1.0.0](LICENSE). The owner also licenses it commercially ([COMMERCIAL.md](COMMERCIAL.md)),
which is why contributions come with a CLA.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you write code

- **Bugs:** open an issue with the *Bug report* form and attach a diagnostics export (File ▸ Export Diagnostics… in the
  app). Read it first: it can contain IP addresses and camera names.
- **A camera that does not work or is missing:** use the *Camera support request* form. A good report says which standards
  the camera speaks (RTSP, ONVIF) and includes its stream URL with the password removed.
- **Features:** open a *Feature request* issue and wait for a reply before building anything big. Small fixes need no
  discussion.
- **Security problems:** do not open an issue. See [SECURITY.md](SECURITY.md).

## Contributor License Agreement (required)

Every contributor signs the [Individual CLA](CLA.md) once. It lets you keep your copyright, and gives the owner the right to
relicense your contribution, including commercially. It is short, written in plain language; read it.

To sign, add one row to the table in [CLA-SIGNATURES.md](CLA-SIGNATURES.md) **in your first pull request**:

```
| Your Name | your-github-username | The email in your git commits | YYYY-MM-DD | 1.0 |
```

A pull request from someone who is not in that table will not be merged. You only sign once, however many pull requests
you send. If you contribute for an employer, read section 6 of the CLA first.

## Building and testing

```sh
cd Packages/CameraBridgeKit && swift test      # engine tests; they need Swift 6.4 (Xcode 27). A few timing-sensitive tests can flake under load: re-run them alone
cd ../.. && xcodegen generate                  # project.yml is the source of truth; the generated project is committed
xcodebuild -project CameraBridge.xcodeproj -scheme CameraBridge -configuration Debug test
```

CI runs the package tests and an unsigned app build on every pull request (`.github/workflows/ci.yml`).

## Guidelines

- Keep changes small and focused; one idea per pull request. Say what changed and why, and how you tested it.
- Add or update tests with the change. The engine's logic lives in `Packages/CameraBridgeKit`; the app's view-model logic in
  `App/Sources/Model` is unit-tested, and views stay thin.
- **Portability rule:** engine modules are portable Swift. Apple-only frameworks belong in `PlatformApple`
  (see `Packages/CameraBridgeKit/Tests/PortabilityTests`).
- Swift 6 language mode, strict concurrency. No force unwraps without a documented reason. Follow the style of the
  surrounding code; match its comments' level of detail.
- No camera passwords, tokens, real IP addresses, serial numbers or images from your home in tests, fixtures, logs or
  screenshots. Test fixtures are synthetic.
- Do not copy code from other projects unless its license allows it, and say so in the pull request (see the CLA, section
  4). Code from projects with no license, or with GPL/AGPL terms, cannot be accepted.
- User-facing text goes through `String(localized:)`; the product name is "Camera Bridge" (two words).
- Brand names of cameras belong in adapter code and the supported-camera data, not in marketing-style text.

## Pull request checklist

The pull request template lists these: CLA row added (first time), tests pass, documentation updated, no secrets.

## License of your contribution

Your contribution is licensed to the public under the Project's license (PolyForm Noncommercial 1.0.0) and to the owner
under the CLA.
