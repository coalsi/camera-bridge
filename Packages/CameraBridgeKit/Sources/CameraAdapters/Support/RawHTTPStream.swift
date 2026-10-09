import BridgeSupport
import Foundation

/// A long-lived plain-HTTP GET on a raw TCP connection (`NetworkTransport`), for event streams that answer
/// `multipart/x-mixed-replace` (Dahua/Amcrest `eventManager.cgi`, DoorBird `monitor.cgi`).
///
/// URLSession is not used for them: it takes such a response apart itself and hands over a part only when the next boundary arrives, so
/// a lone event would wait for the next one. Here the bytes reach the reader as they arrive and the reader does its own framing.
///
/// Authentication: the request goes out without credentials first (a camera answers 401 with its challenge; no login is attempted),
/// then once more on a new connection with the Digest (or, if that is all the camera offers, Basic) answer. A second 401 is returned
/// to the caller, who treats it as rejected credentials. HTTPS is not possible on this path.
enum RawHTTPStream {
    struct Opened: Sendable {
        var status: Int
        var headers: HTTPHeaders
        /// The body as it arrives (chunked encoding removed).
        var body: AsyncThrowingStream<Data, any Error>
        /// Closes the connection; the body ends.
        var close: @Sendable () -> Void
    }

    static let maximumHeadSize = 64 * 1024

    static func open(transport: any NetworkTransport, host: String, port: Int, target: String, credentials: HTTPCredentials?,
                     timeout: Duration = .seconds(10)) async throws -> Opened {
        let first = try await request(transport: transport, host: host, port: port, target: target, authorization: nil, timeout: timeout)
        guard first.status == 401, let credentials else { return first }
        let challengeText = first.headers.values(for: "WWW-Authenticate")
        first.close()
        let header: String
        if let digest = challengeText.compactMap(DigestChallenge.parse).first {
            var authenticator = DigestAuthenticator(credentials: credentials)
            header = authenticator.authorization(for: digest, method: "GET", uri: target)
        } else if challengeText.contains(where: { $0.lowercased().hasPrefix("basic") }) {
            header = BasicAuth.header(credentials)
        } else {
            throw CameraAdapterError.unauthorized
        }
        return try await request(transport: transport, host: host, port: port, target: target, authorization: header, timeout: timeout)
    }

    private static func request(transport: any NetworkTransport, host: String, port: Int, target: String, authorization: String?,
                                timeout: Duration) async throws -> Opened {
        guard let port16 = UInt16(exactly: port) else { throw CameraAdapterError.invalidResponse("invalid port") }
        let bareHost = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        let connection = try await transport.connect(host: bareHost, port: port16, timeout: timeout)
        var headers = HTTPHeaders([("Host", port == 80 ? host : "\(host):\(port)"), ("User-Agent", "CameraBridge"), ("Accept", "*/*"),
                                   ("Connection", "keep-alive")])
        if let authorization { headers.add("Authorization", authorization) }
        let wire = HTTPSerializer.request(HTTPRequestHead(method: "GET", target: target, headers: headers), body: Data())
        do {
            try await connection.send(wire)
            let (head, rest) = try await withTimeout(timeout) { try await readHead(connection) }
            return makeOpened(head: head, rest: rest, connection: connection)
        } catch {
            connection.close()
            throw error
        }
    }

    /// Reads up to the end of the response head; returns it and the body bytes already read.
    private static func readHead(_ connection: any TCPConnection) async throws -> (HTTPResponseHead, Data) {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            guard let chunk = try await connection.receive(maximumLength: 16 * 1024) else { throw TransportError.closed }
            buffer.append(chunk)
            if let range = buffer.range(of: terminator) {
                let headData = buffer[buffer.startIndex..<range.lowerBound]
                let rest = Data(buffer[range.upperBound...])
                return (try parseHead(headData), rest)
            }
            if buffer.count > maximumHeadSize { throw CameraAdapterError.invalidResponse("response head too large") }
        }
    }

    static func parseHead(_ data: Data) throws -> HTTPResponseHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw CameraAdapterError.invalidResponse("empty response") }
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else {
            throw CameraAdapterError.invalidResponse("not an HTTP response")
        }
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return HTTPResponseHead(version: String(status[0]), status: code, reason: status.count > 2 ? String(status[2]) : "", headers: headers)
    }

    private static func makeOpened(head: HTTPResponseHead, rest: Data, connection: any TCPConnection) -> Opened {
        let chunked = head.headers.values(for: "Transfer-Encoding").contains { $0.lowercased().contains("chunked") }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let task = Task {
            var decoder = ChunkedDecoder()
            func deliver(_ data: Data) {
                if chunked {
                    let decoded = decoder.feed(data)
                    if !decoded.isEmpty { continuation.yield(decoded) }
                } else if !data.isEmpty {
                    continuation.yield(data)
                }
            }
            deliver(rest)
            do {
                while !Task.isCancelled {
                    guard let data = try await connection.receive(maximumLength: 16 * 1024) else { break }
                    deliver(data)
                    if decoder.isFinished { break }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Task.isCancelled ? nil : error)
            }
            connection.close()
        }
        continuation.onTermination = { _ in
            task.cancel()
            connection.close()
        }
        return Opened(status: head.status, headers: head.headers, body: stream, close: {
            task.cancel()
            connection.close()
            continuation.finish()
        })
    }
}

/// Removes HTTP chunked transfer coding from a byte stream (sizes in hex, extensions ignored, trailers dropped).
struct ChunkedDecoder: Sendable {
    private var buffer = Data()
    private var remaining = 0
    private var expectingCRLF = false
    private(set) var isFinished = false

    mutating func feed(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while !isFinished {
            if remaining > 0 {
                let take = min(remaining, buffer.count)
                guard take > 0 else { break }
                output.append(buffer.prefix(take))
                buffer = Data(buffer.dropFirst(take))
                remaining -= take
                if remaining == 0 { expectingCRLF = true }
            } else if expectingCRLF {
                guard buffer.count >= 2 else { break }
                buffer = Data(buffer.dropFirst(2))
                expectingCRLF = false
            } else {
                guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                    if buffer.count > 1024 { buffer = Data(); isFinished = true }
                    break
                }
                let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                let size = line.split(separator: ";", maxSplits: 1).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                guard let size, size >= 0 else { isFinished = true; break }
                if size == 0 { isFinished = true } else { remaining = size }
            }
        }
        return output
    }
}
