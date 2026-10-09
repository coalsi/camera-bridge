import BridgeDaemon
import Foundation

// The Camera Bridge OS daemon: the bridge engine and its web interface. All of it lives in BridgeDaemon (so it can be tested);
// run `camerabridged --help` for the flags.
exit(await DaemonMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
