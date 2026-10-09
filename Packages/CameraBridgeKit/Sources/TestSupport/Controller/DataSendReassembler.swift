// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (dataSend `data` event layout of lib/camera/RecordingManagement.ts CameraRecordingStream; research brief §3.8.)

import Foundation
import HDS

/// Reassembles the chunked packets of HKSV `dataSend/data` events into the initialization segment and whole
/// fragments, checking the rules of research brief §3.8 on the way:
/// - body `{streamId, packets: [{data, metadata: {dataType, dataSequenceNumber, dataChunkSequenceNumber,
///   isLastDataChunk, dataTotalSize?}}], endOfStream?}`;
/// - the first packet (sequence 1) is `mediaInitialization`, later ones `mediaFragment`, sequences 2, 3, … in order;
/// - chunks are numbered from 1 within a packet, carry at most `maximumChunkSize` (0x40000) bytes; `dataTotalSize` is
///   required on chunk 1, absent (or null) on later chunks, and equals the reassembled size (a packet that grows past it
///   fails at that chunk);
/// - `endOfStream` only on the last chunk of the final packet, and nothing after it.
public struct DataSendReassembler: Sendable {
    public static let maximumChunkSize = 0x40000

    public enum Violation: Error, Equatable, Sendable, CustomStringConvertible {
        case malformed(String)
        case wrongStream(expected: Int64, got: Int64)
        case unexpectedDataType(sequence: Int64, got: String)
        case sequenceOutOfOrder(expected: Int64, got: Int64)
        case chunkOutOfOrder(sequence: Int64, expected: Int64, got: Int64)
        case chunkTooLarge(sequence: Int64, chunk: Int64, size: Int)
        case totalSizeMismatch(sequence: Int64, declared: Int64, actual: Int)
        case totalSizeOnLaterChunk(sequence: Int64, chunk: Int64)
        case missingTotalSize(sequence: Int64)
        case endOfStreamBeforeLastChunk(sequence: Int64)
        case dataAfterEndOfStream

        public var description: String {
            switch self {
            case .malformed(let what): "malformed dataSend data event: \(what)"
            case .wrongStream(let expected, let got): "streamId \(got), expected \(expected)"
            case .unexpectedDataType(let sequence, let got): "packet \(sequence) has dataType \(got)"
            case .sequenceOutOfOrder(let expected, let got): "dataSequenceNumber \(got), expected \(expected)"
            case .chunkOutOfOrder(let sequence, let expected, let got): "packet \(sequence): chunk \(got), expected \(expected)"
            case .chunkTooLarge(let sequence, let chunk, let size): "packet \(sequence) chunk \(chunk) has \(size) bytes (> 0x40000)"
            case .totalSizeMismatch(let sequence, let declared, let actual): "packet \(sequence): dataTotalSize \(declared), got \(actual) bytes"
            case .totalSizeOnLaterChunk(let sequence, let chunk): "packet \(sequence) chunk \(chunk) repeats dataTotalSize"
            case .missingTotalSize(let sequence): "packet \(sequence): chunk 1 has no dataTotalSize"
            case .endOfStreamBeforeLastChunk(let sequence): "endOfStream on a non-final chunk of packet \(sequence)"
            case .dataAfterEndOfStream: "data after endOfStream"
            }
        }
    }

    /// One reassembled packet.
    public struct Packet: Sendable, Equatable {
        public var dataType: String
        public var sequenceNumber: Int64
        public var data: Data
        public var chunkCount: Int
        public var isInitialization: Bool { dataType == "mediaInitialization" }
    }

    public let streamID: Int64
    public let maximumChunkSize: Int
    public private(set) var endOfStream = false
    public private(set) var chunksReceived = 0
    public private(set) var completedPackets = 0

    private var expectedSequence: Int64 = 1
    private var current: (sequence: Int64, dataType: String, data: Data, nextChunk: Int64, declaredTotal: Int64?)?

    public init(streamID: Int64, maximumChunkSize: Int = DataSendReassembler.maximumChunkSize) {
        self.streamID = streamID
        self.maximumChunkSize = maximumChunkSize
    }

    /// True while a packet has chunks but not its last one.
    public var hasPartialPacket: Bool { current != nil }

    /// Consumes one `data` event body; returns the packets it completed.
    public mutating func consume(_ body: HDSDictionary) throws(Violation) -> [Packet] {
        guard case .int(let stream)? = body["streamId"] else { throw .malformed("streamId") }
        guard stream == streamID else { throw .wrongStream(expected: streamID, got: stream) }
        guard !endOfStream else { throw .dataAfterEndOfStream }
        guard case .array(let packets)? = body["packets"] else { throw .malformed("packets") }
        var endOfStreamFlag = false
        if let flag = body["endOfStream"] {
            switch flag {
            case .bool(let value): endOfStreamFlag = value
            case .null: endOfStreamFlag = false
            default: throw .malformed("endOfStream")
            }
        }
        var completed: [Packet] = []
        var lastChunkCompletedPacket = false
        for packet in packets {
            let (done, finished) = try consumeChunk(packet)
            if let done { completed.append(done) }
            lastChunkCompletedPacket = finished
        }
        if endOfStreamFlag {
            guard lastChunkCompletedPacket else { throw .endOfStreamBeforeLastChunk(sequence: current?.sequence ?? expectedSequence) }
            endOfStream = true
        }
        return completed
    }

    private mutating func consumeChunk(_ value: HDSValue) throws(Violation) -> (Packet?, Bool) {
        guard case .dictionary(let packet) = value else { throw .malformed("packet") }
        guard case .data(let data)? = packet["data"] else { throw .malformed("packet data") }
        guard case .dictionary(let metadata)? = packet["metadata"] else { throw .malformed("metadata") }
        guard case .string(let dataType)? = metadata["dataType"] else { throw .malformed("dataType") }
        guard case .int(let sequence)? = metadata["dataSequenceNumber"] else { throw .malformed("dataSequenceNumber") }
        guard case .int(let chunk)? = metadata["dataChunkSequenceNumber"] else { throw .malformed("dataChunkSequenceNumber") }
        guard case .bool(let isLast)? = metadata["isLastDataChunk"] else { throw .malformed("isLastDataChunk") }
        var declaredTotal: Int64?
        switch metadata["dataTotalSize"] {
        case .int(let total)? where total >= 0: declaredTotal = total
        case nil, .null?: declaredTotal = nil
        default: throw .malformed("dataTotalSize")
        }
        chunksReceived += 1
        guard data.count <= maximumChunkSize else { throw .chunkTooLarge(sequence: sequence, chunk: chunk, size: data.count) }

        if var open = current {
            guard sequence == open.sequence else { throw .sequenceOutOfOrder(expected: open.sequence, got: sequence) }
            guard chunk == open.nextChunk else { throw .chunkOutOfOrder(sequence: sequence, expected: open.nextChunk, got: chunk) }
            guard declaredTotal == nil else { throw .totalSizeOnLaterChunk(sequence: sequence, chunk: chunk) }
            guard dataType == open.dataType else { throw .unexpectedDataType(sequence: sequence, got: dataType) }
            open.data.append(data)
            open.nextChunk += 1
            current = open
        } else {
            guard sequence == expectedSequence else { throw .sequenceOutOfOrder(expected: expectedSequence, got: sequence) }
            guard chunk == 1 else { throw .chunkOutOfOrder(sequence: sequence, expected: 1, got: chunk) }
            let expectedType = sequence == 1 ? "mediaInitialization" : "mediaFragment"
            guard dataType == expectedType else { throw .unexpectedDataType(sequence: sequence, got: dataType) }
            guard let declaredTotal else { throw .missingTotalSize(sequence: sequence) }
            current = (sequence, dataType, data, 2, declaredTotal)
        }
        if let open = current, let declared = open.declaredTotal, Int64(open.data.count) > declared {
            throw .totalSizeMismatch(sequence: open.sequence, declared: declared, actual: open.data.count)
        }
        guard isLast, let finished = current else { return (nil, false) }
        if let declared = finished.declaredTotal, declared != Int64(finished.data.count) {
            throw .totalSizeMismatch(sequence: finished.sequence, declared: declared, actual: finished.data.count)
        }
        current = nil
        expectedSequence = finished.sequence + 1
        completedPackets += 1
        return (Packet(dataType: finished.dataType, sequenceNumber: finished.sequence, data: finished.data, chunkCount: Int(finished.nextChunk - 1)), true)
    }
}

/// What a controller received for one HKSV recording stream.
public struct RecordingCapture: Sendable {
    public var streamID: Int64
    /// The `mediaInitialization` packet (ftyp + moov), if it arrived.
    public var initialization: Data?
    /// Whole `mediaFragment` packets (moof + mdat), in order.
    public var fragments: [Data]
    /// Chunk count per packet, init first.
    public var chunkCounts: [Int]
    /// The accessory set `endOfStream`.
    public var endOfStream: Bool
    /// The accessory closed the stream (`dataSend/close`) with this reason.
    public var closeReason: HDSProtocolReason?
    /// When each packet completed (init first).
    public var arrivalTimes: [ContinuousClock.Instant]

    public init(streamID: Int64) {
        self.streamID = streamID
        fragments = []
        chunkCounts = []
        endOfStream = false
        arrivalTimes = []
    }

    /// `initialization` followed by every fragment: a playable fragmented MP4 file.
    public var mp4: Data {
        var out = initialization ?? Data()
        for fragment in fragments { out.append(fragment) }
        return out
    }
}
