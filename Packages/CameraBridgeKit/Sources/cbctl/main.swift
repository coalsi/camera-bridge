import Foundation
import TestSupport

// cbctl — developer HAP controller for CameraBridge accessories (dev-only; never shipped).
// The commands live in TestSupport's `ControllerCLI` (so tests can drive them); this executable only forwards the
// arguments. It connects by host:port and never advertises; pairing data is kept in ~/.cbctl/ ($CBCTL_HOME, --home).

let status = await ControllerCLI.main(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
