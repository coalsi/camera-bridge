# cbctl

The developer HAP controller CLI lives in the Swift package as the executable target
`Packages/CameraBridgeKit/Sources/cbctl` (SwiftPM cannot build sources outside the package root).

```bash
cd Packages/CameraBridgeKit && swift run cbctl --help
```

Dev-only; never embedded in the app. The commands (pair, accessories, watch-motion, snapshot, live, record, unpair)
live in TestSupport's `ControllerCLI`; usage, options and exit codes are in
[`Packages/CameraBridgeKit/Sources/cbctl/README.md`](../../Packages/CameraBridgeKit/Sources/cbctl/README.md).
