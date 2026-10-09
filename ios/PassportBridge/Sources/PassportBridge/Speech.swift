import Foundation
import PassportOpus

public enum SpeechFailure: Error { case format, codec, cloud(Int), incomplete, limit }
public enum SpeechCommand: Sendable {
    case request(session: UInt32, text: String, limit: UInt32)
    case status(SpeechStatus)
}
public struct SpeechStatus: Sendable, Equatable {
    public let session: UInt32, limit: UInt32
    public let state: UInt8
    public init(_ data: Data) throws {
        let bytes = Array(data)
        guard bytes.count == 9, bytes[8] <= 5 else { throw SpeechFailure.format }
        func number(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        session = number(0); limit = number(4); state = bytes[8]
    }
}
public func speechPacket(session: UInt32, frame: UInt32, kind: UInt8, opus: Data = Data()) -> Data {
    var bytes: [UInt8] = []
    for n in [session, frame] { bytes += (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    bytes.append(kind)
    return Data(bytes) + opus
}

/// Keep punctuation and order; bound each synthesis call without summarizing.
public func speechSentences(_ text: String) -> [String] {
    var result: [String] = [], part = ""
    for character in text {
        part.append(character)
        if "。！？!?；;\n".contains(character) || part.count >= 80 {
            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
            part = ""
        }
    }
    if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
    return result
}

/// One encoder per speech session, preserving predictor state across sentences.
public final class SpeechEncoder {
    private let encoder: UnsafeMutableRawPointer
    private var pending: [Int16] = []
    public init() throws {
        guard let encoder = passport_opus_encoder_create() else { throw SpeechFailure.codec }
        self.encoder = encoder
    }
    deinit { passport_opus_encoder_destroy(encoder) }
    public func feed(_ samples: [Int16], end: Bool = false) throws -> [Data] {
        pending += samples
        // Flush the codec lookahead so the final consonant is not cut off.
        if end { pending += Array(repeating: 0, count: 960) }
        if end, !pending.isEmpty, pending.count % 960 != 0 { pending += Array(repeating: 0, count: 960 - pending.count % 960) }
        var packets: [Data] = [], offset = 0
        while pending.count - offset >= 960 {
            var out = [UInt8](repeating: 0, count: 120)
            let n = pending.withUnsafeBufferPointer { pcm in
                passport_opus_encode(encoder, pcm.baseAddress! + offset, &out)
            }
            guard n == 120 else { throw SpeechFailure.codec }
            packets.append(Data(out)); offset += 960
        }
        pending.removeFirst(offset)
        return packets
    }
}

/// Incremental adjacent JSON objects from Volcengine V3 HTTP chunked. Network
/// chunk boundaries are unrelated to JSON boundaries; completion is explicit.
public struct VolcSpeechParser {
    private var record = Data()
    private var depth = 0, quoted = false, escaped = false
    public private(set) var completed = false
    public init() {}
    public mutating func feed(_ data: Data) throws -> [Data] {
        var audio: [Data] = []
        for byte in data {
            if depth == 0 {
                if [9,10,13,32].contains(byte) { continue }
                guard byte == 123, !completed else { throw SpeechFailure.format }
            }
            record.append(byte)
            guard record.count <= 256 * 1024 else { throw SpeechFailure.limit }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 { depth -= 1 }
            if depth == 0 {
                guard let object = try JSONSerialization.jsonObject(with: record) as? [String: Any],
                      let code = object["code"] as? Int else { throw SpeechFailure.format }
                if code == 20_000_000 { completed = true }
                else if code != 0 { throw SpeechFailure.cloud(code) }
                if let encoded = object["data"] as? String, !encoded.isEmpty {
                    guard let bytes = Data(base64Encoded: encoded) else { throw SpeechFailure.format }
                    audio.append(bytes)
                }
                record.removeAll(keepingCapacity: true)
            }
        }
        return audio
    }
    public func finish() throws {
        guard completed, record.isEmpty else { throw SpeechFailure.incomplete }
    }
}
