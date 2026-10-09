import BridgeSupport
import Foundation
import Synchronization

/// One gate per camera address: HTTP requests to a camera that allows only a few connections (a Wi-Fi doorbell, above all)
/// go through it one at a time, whichever client of the app sends them (the driver's API session, a settings change, an
/// event poll, a snapshot). The gates live as long as the process: a camera is a few dozen bytes.
enum CameraHTTPGates {
    private static let gates = Mutex<[String: AsyncSerialLock]>([:])

    static func gate(for endpoint: CameraEndpoint) -> AsyncSerialLock {
        let key = "\(endpoint.host.lowercased()):\(endpoint.httpPort)"
        return gates.withLock { gates in
            if let gate = gates[key] { return gate }
            let gate = AsyncSerialLock()
            gates[key] = gate
            return gate
        }
    }
}

extension CameraReachability {
    /// What a failed request to a camera API shows: the camera answering with an error (rejected credentials, an API error
    /// code, a missing page) means it is there; a gateway error (502, 503, 504) or no answer at all means it is not.
    /// `CameraOfflineError` (nothing was sent) and cancellation show nothing.
    func report(adapterError error: any Error) {
        switch error {
        case is CameraOfflineError, is CancellationError:
            return
        case CameraAdapterError.httpStatus(let status):
            if Self.isGatewayFailure(httpStatus: status) { reportUnreachable() } else { reportReachable() }
        case is CameraAdapterError:
            reportReachable()
        default:
            report(error)
        }
    }
}
