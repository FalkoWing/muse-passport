import Foundation
import PassportOpus

public enum SpeechFailure: Error { case format, codec, cloud(Int), incomplete, limit }
public enum SpeechCommand: Sendable {
    case request(session: UInt32, text: String, limit: UInt32)
    case followRequest(session: UInt32, text: String, limit: UInt32)
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

/// Keep spoken text and punctuation together within 80 characters per call.
/// Standalone punctuation/markup has no speech content and is not synthesized.
public func speechSentences(_ text: String) -> [String] {
    var result: [String] = [], part = ""
    let characters = Array(text)
    func appendPart() {
        if part.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            result.append(part)
        }
    }
    for (index, character) in characters.enumerated() {
        part.append(character)
        let end = "。！？!?；;\n".contains(character)
        let nextEnd = index + 1 < characters.count && "。！？!?；;\n".contains(characters[index + 1])
        if part.count >= 80 || (end && !nextEnd) {
            appendPart()
            part = ""
        }
    }
    appendPart()
    return result
}

/// One original Unicode-scalar offset per retained scalar.
public struct SpeechMappedText: Sendable {
    public var text: String
    public var origins: [Int]
    static func original(_ text: String) -> Self { Self(text: text, origins: Array(0..<text.unicodeScalars.count)) }
    static var empty: Self { Self(text: "", origins: []) }
    func slice(_ from: Int, _ to: Int) -> Self {
        Self(text: speechSlice(text.unicodeScalars.map(\.value), from, to), origins: Array(origins[from..<to]))
    }
    mutating func append(_ other: Self) { text += other.text; origins += other.origins }
    mutating func point(_ value: UInt32, _ origin: Int) { text.unicodeScalars.append(Unicode.Scalar(value)!); origins.append(origin) }
    func replacing(_ pattern: String, group: Int = 0) -> Self {
        let regex = try! NSRegularExpression(pattern: pattern)
        var out = Self.empty, at = 0
        func scalarOffset(_ offset: Int) -> Int { String(decoding: text.utf16.prefix(offset), as: UTF16.self).unicodeScalars.count }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let start = scalarOffset(match.range.location), end = scalarOffset(NSMaxRange(match.range))
            out.append(slice(at, start))
            if group > 0 { out.append(slice(scalarOffset(match.range(at: group).location), scalarOffset(NSMaxRange(match.range(at: group))))) }
            at = end
        }
        out.append(slice(at, origins.count)); return out
    }
}
public struct SpeechSegment: Sendable {
    public let text: String
    public let origin: Int
}
public func speechSegments(_ original: String) -> [SpeechSegment] {
    let mapped = cleanSpeechMapped(original)
    let characters = Array(mapped.text)
    var result: [SpeechSegment] = [], start = 0, scalarStart = 0, scalarEnd = 0
    for (index, character) in characters.enumerated() {
        scalarEnd += character.unicodeScalars.count
        let end = "。！？!?；;\n".contains(character)
        let nextEnd = index + 1 < characters.count && "。！？!?；;\n".contains(characters[index + 1])
        if index - start + 1 >= 80 || end && !nextEnd || index + 1 == characters.count {
            let part = mapped.slice(scalarStart, scalarEnd)
            if let first = part.text.unicodeScalars.firstIndex(where: { CharacterSet.alphanumerics.contains($0) }) {
                let offset = part.text.unicodeScalars.distance(from: part.text.unicodeScalars.startIndex, to: first)
                result.append(SpeechSegment(text: part.text, origin: part.origins[offset]))
            }
            start = index + 1; scalarStart = scalarEnd
        }
    }
    return result
}
public func cleanSpeechText(_ text: String) -> String { cleanSpeechMapped(text).text }
/// Same cleaning rules, retaining provenance instead of searching repeated text.
public func cleanSpeechMapped(_ text: String) -> SpeechMappedText {
    let original = SpeechMappedText.original(text), lines = text.components(separatedBy: "\n")
    var starts = [0]
    for line in lines.dropLast() { starts.append(starts.last! + line.unicodeScalars.count + 1) }
    var out = SpeechMappedText.empty, index = 0
    while index < lines.count {
        var line = original.slice(starts[index], starts[index] + lines[index].unicodeScalars.count)
        if let opening = speechFence(line.text) {
            var end = index + 1
            let pattern = "^ {0,3}" + opening.mark + "{\(opening.count),}[ \\t]*\\r?$"
            while end < lines.count && !speechMatches(lines[end], pattern) { end += 1 }
            if end == lines.count { out.append(original.slice(starts[index], original.origins.count)); break }
            index = end
        } else {
            line = line.replacing("^[ \\t]*(-{3,}|\\*{3,}|_{3,})[ \\t]*\\r?$")
            for pattern in ["^#{1,6}[ \\t]+", "^> ?", "^[ \\t]?[-*+][ \\t]+", "^\\d{1,3}[.)][ \\t]+"] { line = line.replacing(pattern) }
            let inline = inlineSpeech(line)
            out.append(inline.text)
            if inline.openCode {
                if index + 1 < lines.count { out.append(original.slice(starts[index] + lines[index].unicodeScalars.count, original.origins.count)) }
                break
            }
        }
        if index + 1 < lines.count { out.point(10, starts[index] + lines[index].unicodeScalars.count) }
        index += 1
    }
    return out
}
private func speechMatches(_ text: String, _ pattern: String) -> Bool {
    try! NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}
private func speechFence(_ text: String) -> (mark: String, count: Int)? {
    let regex = try! NSRegularExpression(pattern: "^ {0,3}(`{3,}|~{3,})(.*)\\r?$")
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text), let info = Range(match.range(at: 2), in: text) else { return nil }
    let mark = String(text[range].prefix(1))
    guard mark != "`" || !text[info].contains("`") else { return nil }
    return (mark, text[range].count)
}
private func speechSlice(_ points: [UInt32], _ from: Int, _ to: Int) -> String {
    String(String.UnicodeScalarView(points[from..<to].map { Unicode.Scalar($0)! }))
}
private func speechRunEnd(_ points: [UInt32], _ at: Int) -> Int {
    var end = at + 1
    while end < points.count && points[end] == points[at] { end += 1 }
    return end
}
private func speechBalancedEnd(_ points: [UInt32], _ at: Int, _ open: UInt32, _ close: UInt32) -> Int? {
    var depth = 0, index = at
    while index < points.count {
        if points[index] == 92 { index += 2; continue }
        if points[index] == open { depth += 1 }
        if points[index] == close { depth -= 1; if depth == 0 { return index } }
        index += 1
    }
    return nil
}
private func inlineSpeech(_ mapped: SpeechMappedText, depth: Int = 0) -> (text: SpeechMappedText, openCode: Bool) {
    guard depth < 16 else { return (mapped, false) } // Bound nested link labels; unknown structures stay literal.
    let points = mapped.text.unicodeScalars.map(\.value)
    var out = SpeechMappedText.empty, plain = SpeechMappedText.empty, index = 0, openCode = false
    while index < points.count {
        var end = index, literal: SpeechMappedText?
        if points[index] == 92 && index + 1 < points.count {
            end = index + 2; literal = mapped.slice(index, end)
        } else if points[index] == 96 {
            let start = speechRunEnd(points, index)
            var close = start
            while close < points.count {
                if points[close] != 96 { close += 1; continue }
                let next = speechRunEnd(points, close)
                if next - close == start - index { break }
                close = next
            }
            openCode = close == points.count
            end = openCode ? points.count : close + start - index
            literal = close == points.count ? mapped.slice(index, end) : mapped.slice(start, close)
        } else if points[index] == 91 || (points[index] == 33 && index + 1 < points.count && points[index + 1] == 91) {
            let label = points[index] == 33 ? index + 1 : index
            if let close = speechBalancedEnd(points, label, 91, 93), close + 1 < points.count, points[close + 1] == 40,
               let destination = speechBalancedEnd(points, close + 1, 40, 41) {
                end = destination + 1
                literal = points[index] == 33 ? .empty : inlineSpeech(mapped.slice(label + 1, close), depth: depth + 1).text
            } else { end = points.count; literal = mapped.slice(index, end) }
        } else if ["https://", "http://", "www."].contains(where: { prefix in
            let scalars = prefix.unicodeScalars.map(\.value)
            return index + scalars.count <= points.count && Array(points[index..<index + scalars.count]) == scalars
        }) {
            end = index
            while end < points.count && !CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(points[end])!) { end += 1 }
            literal = mapped.slice(index, end)
        }
        if let literal {
            out.append(plainSpeech(plain)); out.append(literal); plain = .empty; index = end
        } else { plain.point(points[index], mapped.origins[index]); index += 1 }
    }
    out.append(plainSpeech(plain)); return (out, openCode)
}
private func plainSpeech(_ mapped: SpeechMappedText) -> SpeechMappedText {
    var mapped = mapped
    let points = mapped.text.unicodeScalars.map(\.value)
    var out = SpeechMappedText.empty, index = 0
    while index < points.count {
        let point = points[index]
        var next = index + 1
        if next < points.count && points[next] == 0xFE0F { next += 1 }
        if ((48...57).contains(point) || point == 35 || point == 42), next < points.count, points[next] == 0x20E3 {
            if (48...57).contains(point) { out.point(point, mapped.origins[index]) }
            index = next + 1; continue
        }
        let isOperator = point == 0x2716 || (0x2795...0x2797).contains(point) || (48...57).contains(point)
        let modified = next < points.count && (0x1F3FB...0x1F3FF).contains(points[next]) && speechTextEmojiModifierBase.contains { $0.contains(point) }
        if !isOperator && (speechEmojiPresentation.contains { $0.contains(point) } || next > index + 1 && speechEmoji.contains { $0.contains(point) } || modified) {
            index = speechEmojiEnd(points, index)
            while index + 1 < points.count && points[index] == 0x200D && speechEmoji.contains(where: { $0.contains(points[index + 1]) }) {
                index = speechEmojiEnd(points, index + 1)
            }
        } else { out.point(point, mapped.origins[index]); index += 1 }
    }
    mapped = out
    for mark in ["\\*\\*", "__", "\\*"] {
        let excluded = mark == "__" ? "_" : "*"
        mapped = mapped.replacing("(?<![A-Za-z0-9_*])" + mark + "([^" + excluded + " \\t\\r\\n\\p{P}](?:[^" + excluded + "\\r\\n]*?[^" + excluded + " \\t\\r\\n])?)" + mark + "(?![A-Za-z0-9_*])", group: 1)
    }
    return mapped
}
private func speechEmojiEnd(_ points: [UInt32], _ at: Int) -> Int {
    var index = at + 1
    while index < points.count && (points[index] == 0xFE0E || points[index] == 0xFE0F || (0x1F3FB...0x1F3FF).contains(points[index]) || (0xE0020...0xE007F).contains(points[index])) { index += 1 }
    return index
}
// Unicode 17 Emoji / Emoji_Presentation, unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt.
// Copyright Unicode, Inc. See shared/UNICODE-LICENSE.txt.
// Emoji_Modifier_Base minus Emoji_Presentation (other bases are already removed).
private let speechTextEmojiModifierBase: [ClosedRange<UInt32>] = [
    0x261D...0x261D, 0x26F9...0x26F9, 0x270C...0x270D,
    0x1F3CB...0x1F3CC, 0x1F574...0x1F575, 0x1F590...0x1F590,
]
private let speechEmoji: [ClosedRange<UInt32>] = [
    0x23...0x23, 0x2A...0x2A, 0x30...0x39, 0xA9...0xA9, 0xAE...0xAE,
    0x203C...0x203C, 0x2049...0x2049, 0x2122...0x2122, 0x2139...0x2139, 0x2194...0x2199,
    0x21A9...0x21AA, 0x231A...0x231B, 0x2328...0x2328, 0x23CF...0x23CF, 0x23E9...0x23F3,
    0x23F8...0x23FA, 0x24C2...0x24C2, 0x25AA...0x25AB, 0x25B6...0x25B6, 0x25C0...0x25C0,
    0x25FB...0x25FE, 0x2600...0x2604, 0x260E...0x260E, 0x2611...0x2611, 0x2614...0x2615,
    0x2618...0x2618, 0x261D...0x261D, 0x2620...0x2620, 0x2622...0x2623, 0x2626...0x2626,
    0x262A...0x262A, 0x262E...0x262F, 0x2638...0x263A, 0x2640...0x2640, 0x2642...0x2642,
    0x2648...0x2653, 0x265F...0x2660, 0x2663...0x2663, 0x2665...0x2666, 0x2668...0x2668,
    0x267B...0x267B, 0x267E...0x267F, 0x2692...0x2697, 0x2699...0x2699, 0x269B...0x269C,
    0x26A0...0x26A1, 0x26A7...0x26A7, 0x26AA...0x26AB, 0x26B0...0x26B1, 0x26BD...0x26BE,
    0x26C4...0x26C5, 0x26C8...0x26C8, 0x26CE...0x26CF, 0x26D1...0x26D1, 0x26D3...0x26D4,
    0x26E9...0x26EA, 0x26F0...0x26F5, 0x26F7...0x26FA, 0x26FD...0x26FD, 0x2702...0x2702,
    0x2705...0x2705, 0x2708...0x270D, 0x270F...0x270F, 0x2712...0x2712, 0x2714...0x2714,
    0x2716...0x2716, 0x271D...0x271D, 0x2721...0x2721, 0x2728...0x2728, 0x2733...0x2734,
    0x2744...0x2744, 0x2747...0x2747, 0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755,
    0x2757...0x2757, 0x2763...0x2764, 0x2795...0x2797, 0x27A1...0x27A1, 0x27B0...0x27B0,
    0x27BF...0x27BF, 0x2934...0x2935, 0x2B05...0x2B07, 0x2B1B...0x2B1C, 0x2B50...0x2B50,
    0x2B55...0x2B55, 0x3030...0x3030, 0x303D...0x303D, 0x3297...0x3297, 0x3299...0x3299,
    0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F170...0x1F171, 0x1F17E...0x1F17F, 0x1F18E...0x1F18E,
    0x1F191...0x1F19A, 0x1F1E6...0x1F1FF, 0x1F201...0x1F202, 0x1F21A...0x1F21A, 0x1F22F...0x1F22F,
    0x1F232...0x1F23A, 0x1F250...0x1F251, 0x1F300...0x1F321, 0x1F324...0x1F393, 0x1F396...0x1F397,
    0x1F399...0x1F39B, 0x1F39E...0x1F3F0, 0x1F3F3...0x1F3F5, 0x1F3F7...0x1F4FD, 0x1F4FF...0x1F53D,
    0x1F549...0x1F54E, 0x1F550...0x1F567, 0x1F56F...0x1F570, 0x1F573...0x1F57A, 0x1F587...0x1F587,
    0x1F58A...0x1F58D, 0x1F590...0x1F590, 0x1F595...0x1F596, 0x1F5A4...0x1F5A5, 0x1F5A8...0x1F5A8,
    0x1F5B1...0x1F5B2, 0x1F5BC...0x1F5BC, 0x1F5C2...0x1F5C4, 0x1F5D1...0x1F5D3, 0x1F5DC...0x1F5DE,
    0x1F5E1...0x1F5E1, 0x1F5E3...0x1F5E3, 0x1F5E8...0x1F5E8, 0x1F5EF...0x1F5EF, 0x1F5F3...0x1F5F3,
    0x1F5FA...0x1F64F, 0x1F680...0x1F6C5, 0x1F6CB...0x1F6D2, 0x1F6D5...0x1F6D8, 0x1F6DC...0x1F6E5,
    0x1F6E9...0x1F6E9, 0x1F6EB...0x1F6EC, 0x1F6F0...0x1F6F0, 0x1F6F3...0x1F6FC, 0x1F7E0...0x1F7EB,
    0x1F7F0...0x1F7F0, 0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FA7C,
    0x1FA80...0x1FA8A, 0x1FA8E...0x1FAC6, 0x1FAC8...0x1FAC8, 0x1FACD...0x1FADC, 0x1FADF...0x1FAEA,
    0x1FAEF...0x1FAF8,
]
private let speechEmojiPresentation: [ClosedRange<UInt32>] = [
    0x231A...0x231B, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3, 0x25FD...0x25FE,
    0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1,
    0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4,
    0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD,
    0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728, 0x274C...0x274C, 0x274E...0x274E,
    0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797, 0x27B0...0x27B0, 0x27BF...0x27BF,
    0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55, 0x1F004...0x1F004, 0x1F0CF...0x1F0CF,
    0x1F18E...0x1F18E, 0x1F191...0x1F19A, 0x1F1E6...0x1F1FF, 0x1F201...0x1F201, 0x1F21A...0x1F21A,
    0x1F22F...0x1F22F, 0x1F232...0x1F236, 0x1F238...0x1F23A, 0x1F250...0x1F251, 0x1F300...0x1F320,
    0x1F32D...0x1F335, 0x1F337...0x1F37C, 0x1F37E...0x1F393, 0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3,
    0x1F3E0...0x1F3F0, 0x1F3F4...0x1F3F4, 0x1F3F8...0x1F43E, 0x1F440...0x1F440, 0x1F442...0x1F4FC,
    0x1F4FF...0x1F53D, 0x1F54B...0x1F54E, 0x1F550...0x1F567, 0x1F57A...0x1F57A, 0x1F595...0x1F596,
    0x1F5A4...0x1F5A4, 0x1F5FB...0x1F64F, 0x1F680...0x1F6C5, 0x1F6CC...0x1F6CC, 0x1F6D0...0x1F6D2,
    0x1F6D5...0x1F6D8, 0x1F6DC...0x1F6DF, 0x1F6EB...0x1F6EC, 0x1F6F4...0x1F6FC, 0x1F7E0...0x1F7EB,
    0x1F7F0...0x1F7F0, 0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FA7C,
    0x1FA80...0x1FA8A, 0x1FA8E...0x1FAC6, 0x1FAC8...0x1FAC8, 0x1FACD...0x1FADC, 0x1FADF...0x1FAEA,
    0x1FAEF...0x1FAF8,
]

public struct SpeechAudioFrame {
    public let opus: Data
    public let origin: UInt32
}

/// One encoder per speech session, preserving predictor state across sentences.
public final class SpeechEncoder {
    private let encoder: UnsafeMutableRawPointer
    private var pending: [Int16] = []
    private var pendingOrigin = UInt32.max, lastOrigin = UInt32.max
    public init() throws {
        guard let encoder = passport_opus_encoder_create() else { throw SpeechFailure.codec }
        self.encoder = encoder
    }
    deinit { passport_opus_encoder_destroy(encoder) }
    public func feed(_ samples: [Int16], end: Bool = false) throws -> [Data] {
        try feedLocated(samples, origin: .max, end: end).map(\.opus)
    }
    public func feedLocated(_ samples: [Int16], origin: UInt32, end: Bool = false) throws -> [SpeechAudioFrame] {
        var packets: [SpeechAudioFrame] = [], offset = 0
        func encodePending() throws {
            var out = [UInt8](repeating: 0, count: 120)
            let n = pending.withUnsafeBufferPointer { passport_opus_encode(encoder, $0.baseAddress!, &out) }
            guard n == 120 else { throw SpeechFailure.codec }
            packets.append(SpeechAudioFrame(opus: Data(out), origin: pendingOrigin))
            pending.removeAll(keepingCapacity: true)
        }
        while offset < samples.count {
            if pending.isEmpty { pendingOrigin = origin }
            let n = min(960 - pending.count, samples.count - offset)
            pending += samples[offset..<offset + n]; offset += n; lastOrigin = origin
            if pending.count == 960 { try encodePending() }
        }
        if end {
            if !pending.isEmpty {
                pending += Array(repeating: 0, count: 960 - pending.count); try encodePending()
            }
            pendingOrigin = lastOrigin; pending = Array(repeating: 0, count: 960)
            try encodePending() // Preserve the codec lookahead tail.
        }
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
