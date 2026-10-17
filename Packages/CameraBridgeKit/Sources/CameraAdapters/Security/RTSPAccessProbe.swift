import BridgeSupport
import Foundation

/// Whether a camera's video plays without a password on the home network: one RTSP `DESCRIBE` without credentials to one of its stream
/// addresses, on a connection of its own. A 200 with the stream's description (SDP) is `on`; 401 or 403 is `off`; any other answer,
/// silence until the timeout, or a closed or refused connection is `unknown`. Credentials are never sent, and a password challenge is never
/// answered: the user info of the address is left out, and an address that carries credentials in its path or query (XMEye
/// `/user=admin&password=…`, `?pwd=…`: what `Redact.url` masks) is `unknown` without connecting, since it would sign in.
public enum RTSPAccessProbe {
    public static let timeout: Duration = .seconds(5)
    /// An answer longer than this is not read further (a description is a few hundred bytes).
    static let answerLimit = 64 << 10

    /// One check of `url` (`rtsp:` only, without credentials in its path or query; anything else is `unknown` and nothing is sent).
    public static func check(url: URL, transport: any NetworkTransport, timeout: Duration = RTSPAccessProbe.timeout) async -> RemoteAccessState {
        let address = url.removingUserInfo
        guard address.scheme?.lowercased() == "rtsp", let host = address.host, !host.isEmpty, Redact.url(address) == address.absoluteString else {
            return .unknown
        }
        let port = UInt16(clamping: address.port ?? 554)
        let request = Self.request(for: address)
        do {
            return try await withTimeout(timeout) {
                let connection = try await transport.connect(host: host, port: port, timeout: timeout)
                defer { connection.close() }
                try await connection.send(request)
                var answer = Data()
                while answer.count < answerLimit {
                    guard let data = try await connection.receive(maximumLength: 16 << 10) else { break }
                    answer.append(data)
                    if let state = classify(answer) { return state }
                }
                return classify(answer, complete: true) ?? .unknown
            }
        } catch {
            return .unknown
        }
    }

    /// `DESCRIBE <url> RTSP/1.0` with nothing that could sign in.
    static func request(for url: URL) -> Data {
        Data("DESCRIBE \(url.absoluteString) RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: Camera Bridge\r\n\r\n".utf8)
    }

    /// What an answer read so far says: nil while its head (or, for a 200, its body) is incomplete. `complete`: the camera closed the
    /// connection, so what arrived is all of it.
    static func classify(_ answer: Data, complete: Bool = false) -> RemoteAccessState? {
        let text = String(decoding: answer, as: UTF8.self)
        guard let headEnd = text.range(of: "\r\n\r\n") else { return complete ? .unknown : nil }
        let lines = text[..<headEnd.lowerBound].components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, status[0].uppercased().hasPrefix("RTSP/"), let code = Int(status[1]) else { return .unknown }
        switch code {
        case 401, 403: return .off
        case 200: break
        default: return .unknown
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = text[headEnd.upperBound...]
        if !complete {
            if let length = headers["content-length"].flatMap(Int.init) {
                if body.utf8.count < length { return nil }
            } else if body.isEmpty {
                return nil   // no length: the body runs to the end of the connection
            }
        }
        let type = headers["content-type"]?.lowercased()
        let isDescription = type?.hasPrefix("application/sdp") == true || (type == nil && body.hasPrefix("v=0"))
        return isDescription && body.hasPrefix("v=") ? .on : .unknown
    }
}
