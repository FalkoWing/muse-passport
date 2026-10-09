import Foundation

public enum ReplyCacheError: Error {
    case lineLimit, malformedEvent, malformedQuery
}

/// The bounded cache of the current turn, fed from Muse's NDJSON subscription.
///
/// It answers the device's two local requests: `/chat/history` polls and the
/// `/passport/reader` pages. Full text stays on the phone, not on the ESP32.
public struct ReplyCache: Sendable {
    /// Bytes of UTF-8 kept per message and per merged reply.
    public static let textLimit = 64 * 1024

    private struct Row: Sendable {
        var seq: Int
        var messageID: String
        var event: String
        var parent: String
        var displayText = ""
        var ready: Bool
        var readerText = ""
        var truncated = false
        var finished = false
    }

    private var buffer: [UInt8] = []
    /// Insertion ordered; the oldest row is evicted first.
    private var rows: [Row] = []
    private var seq = 0
    private var mark = 0
    private var noteID = ""
    private var noteIDs: Set<String> = []

    public init() {}

    /// Starts a new turn: earlier rows are forgotten, sequence numbers are not.
    public mutating func begin() {
        mark = seq
        noteID = ""
        rows.removeAll()
        noteIDs.removeAll()
    }

    /// A new subscription starts on a line boundary: whatever the previous one
    /// left unfinished is dropped, the rows are kept.
    public mutating func resubscribed() {
        buffer.removeAll()
    }

    /// Records the upload acknowledgement, which may name both the uploaded
    /// note and the message it replies to.
    public mutating func note(_ identifier: String, replyTo replyIdentifier: String = "") {
        noteID = identifier
        noteIDs = Set([identifier, replyIdentifier].filter { !$0.isEmpty })
        if !identifier.isEmpty, !rows.contains(where: { $0.messageID == identifier }) {
            row(identifier, event: "message.user", text: "[Voice note]", ready: true, parent: "")
        }
    }

    private mutating func row(_ identifier: String, event: String, text: String, ready: Bool, parent: String) {
        // Real Muse delta events may put the assistant's own stream/message
        // ID in reply_to_message_id. This is not a parent link. Treat it like
        // an absent parent and never overwrite a genuine earlier user link.
        let parent = event == "message.assistant" && parent == identifier ? "" : parent
        let index: Int
        if let existing = rows.firstIndex(where: { $0.messageID == identifier }) {
            index = existing
        } else {
            seq += 1
            rows.append(Row(seq: seq, messageID: identifier, event: event, parent: parent, ready: ready))
            index = rows.count - 1
        }
        let limited = Self.truncated(text, to: Self.textLimit)
        var text = limited.text
        let finished = rows[index].finished
        if finished, !ready { text = rows[index].readerText }
        if text.isEmpty { text = rows[index].readerText }
        rows[index].event = event
        rows[index].readerText = text
        rows[index].truncated = limited.truncated || rows[index].truncated
        rows[index].displayText = Self.truncated(text, to: 8000).text
        rows[index].ready = ready || finished
        if ready, event == "message.assistant" { rows[index].finished = true }
        if !parent.isEmpty { rows[index].parent = parent }
        if rows.count > 32 { rows.removeFirst(rows.count - 32) }
    }

    /// Consumes subscription bytes; lines may arrive split anywhere.
    public mutating func feed(_ data: Data) throws {
        buffer += data
        guard buffer.count <= 1024 * 1024 else { throw ReplyCacheError.lineLimit }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeFirst(newline + 1)
            guard line.contains(where: { !" \t\r\u{0B}\u{0C}".utf8.contains($0) }) else { continue }
            guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ReplyCacheError.malformedEvent
            }
            guard item["type"] as? String == "event" else { continue }
            let payload = item["payload"] as? [String: Any] ?? [:]
            func text(_ source: [String: Any], _ key: String) -> String { source[key] as? String ?? "" }
            let identifier = [text(payload, "message_id"), text(item, "message_id"), text(payload, "id")]
                .first { !$0.isEmpty } ?? ""
            guard !identifier.isEmpty else { continue }
            let parent = [text(payload, "reply_to_message_id"), text(payload, "parent_message_id")]
                .first { !$0.isEmpty } ?? ""
            let display = [text(payload, "display_text"), text(payload, "content")].first { !$0.isEmpty } ?? ""
            let known = rows.first { $0.messageID == identifier }?.readerText ?? ""
            switch text(item, "event") {
            case let event where event == "message.user" || event == "message.assistant":
                row(identifier, event: event, text: display,
                    ready: payload["display_text_ready"] as? Bool != false, parent: parent)
            case "delta.message_start":
                row(identifier, event: "message.assistant", text: "", ready: false, parent: parent)
            case "delta.text_append":
                row(identifier, event: "message.assistant", text: known + text(payload, "text"),
                    ready: false, parent: parent)
            case "delta.message_done":
                row(identifier, event: "message.assistant", text: display.isEmpty ? known : display,
                    ready: true, parent: parent)
            default:
                break
            }
        }
    }

    /// Assistant replies can form chains, and the acknowledgement may name both
    /// the uploaded note and the message it replies to (upstream SDK).
    private var related: Set<String> {
        var related = noteIDs
        for _ in rows {
            for row in rows where row.event == "message.assistant" && (row.parent.isEmpty || related.contains(row.parent)) {
                related.insert(row.messageID)
            }
        }
        return related
    }

    public func speechText(note: String, message: String) -> String? {
        guard note == noteID, !note.isEmpty, related.contains(message),
              let row = rows.first(where: { $0.messageID == message }),
              row.event == "message.assistant", row.ready else { return nil }
        return row.readerText
    }

    /// The local `/chat/history` endpoint: at most one event after `after_seq`.
    public func page(_ path: String) throws -> Data {
        let query = Self.query(path)
        var events: [[String: Any]] = []
        if let after = query["after_seq"]?.first {
            guard let after = Int(after.trimmingCharacters(in: .whitespaces)) else { throw ReplyCacheError.malformedQuery }
            let related = related
            for row in rows where row.seq > after {
                let ownUser = row.event == "message.user" && noteIDs.contains(row.messageID)
                let ownReply = row.event == "message.assistant" && !noteID.isEmpty
                    && (row.parent.isEmpty || noteIDs.contains(row.parent) || related.contains(row.parent))
                guard ownUser || ownReply else { continue }
                var text = row.displayText
                if query["caption"] == ["1"] { text = Self.truncated(text, to: 768).text }
                events = [[
                    "seq": row.seq, "event_name": row.event, "display_text": text, "display_text_ready": row.ready,
                    "message_id": ownReply ? row.messageID : noteID,
                    "reply_to_message_id": ownReply ? noteID : row.parent,
                ]]
                break
            }
        } else if mark != 0 {
            // Mark the start of this turn, rather than a user event which can
            // arrive before the upload ACK and the firmware's first poll.
            events = [["seq": mark, "event_name": "marker"]]
        }
        return Self.json(["ok": true, "result": ["chat_events": events]])
    }

    /// The local `/passport/reader` endpoint. Never forwarded to the Muse VM.
    public func readerPage(_ path: String) throws -> Data {
        let query = Self.query(path)
        guard !noteID.isEmpty, query["note"]?.first ?? "" == noteID else { return Data(#"{"ok":false}"#.utf8) }
        func number(_ key: String, default value: Int) throws -> Int {
            guard let text = query[key]?.first else { return value }
            guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)) else { throw ReplyCacheError.malformedQuery }
            return parsed
        }
        let columns = max(1, min(12, try number("cols", default: 12)))
        let lines = max(1, min(6, try number("lines", default: 6)))
        let related = related
        var users: [String] = []
        var replies: [String] = []
        var truncated = false
        var ready = true
        for row in rows {
            if row.event == "message.user", noteIDs.contains(row.messageID) {
                var text = row.readerText
                if let attachment = text.range(of: "\n[file:") { text = String(text[..<attachment.lowerBound]) }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text != "[Voice note]" {
                    users.append(text)
                    truncated = truncated || row.truncated
                }
            } else if row.event == "message.assistant", related.contains(row.messageID) {
                ready = ready && row.ready
                // Stable completed messages: their page boundaries cannot move
                // under the reader as more streaming tokens arrive.
                if row.ready, !row.readerText.isEmpty {
                    replies.append(row.readerText)
                    truncated = truncated || row.truncated
                }
            }
        }
        let userPages = wrapPages(users.first ?? "", columns: columns, lines: lines)
        let merged = Self.truncated(replies.joined(separator: "\n\n"), to: Self.textLimit)
        truncated = truncated || merged.truncated
        let replyPages = wrapPages(merged.text, columns: columns, lines: lines)
        let pages = userPages + replyPages
        var selected = try number("page", default: -1)
        if selected < 0 { selected = replyPages.isEmpty ? 0 : userPages.count }
        selected = max(0, min(pages.count - 1, selected))
        let isReply = selected >= userPages.count
        return Self.json([
            "ok": true, "page": selected, "pages": pages.count, "role": isReply ? "assistant" : "user",
            "role_page": pages.isEmpty ? 0 : selected - (isReply ? userPages.count : 0) + 1,
            "role_pages": isReply ? replyPages.count : userPages.count,
            "text": pages.isEmpty ? "" : pages[selected],
            "truncated": truncated, "ready": !replyPages.isEmpty && ready,
        ])
    }

    // MARK: Helpers

    /// Cuts at a byte limit without splitting a UTF-8 character.
    private static func truncated(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return (text, false) }
        var cut = limit
        while cut > 0, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
        return (String(decoding: bytes[..<cut], as: UTF8.self), true)
    }

    /// Query values by key; blank values are dropped, as the Android bridge does.
    private static func query(_ path: String) -> [String: [String]] {
        guard let start = path.firstIndex(of: "?") else { return [:] }
        let text = path[path.index(after: start)...].prefix { $0 != "#" }
        var result: [String: [String]] = [:]
        func decode(_ part: Substring) -> String {
            let spaced = part.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            result[decode(parts[0]), default: []].append(decode(parts[1]))
        }
        return result
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}

/// Conservative 16px cells inside a 200px label; whole Unicode characters.
///
/// Explicit line breaks, including blank paragraphs, count as lines. Pages
/// do not overlap. Spaces at a soft wrap are omitted, never actual words.
public func wrapPages(_ text: String, columns: Int = 12, lines: Int = 6) -> [String] {
    guard !text.isEmpty else { return [] }
    // Count code points, as the device does, not grapheme clusters.
    let space: Unicode.Scalar = " "
    let scalars = text.unicodeScalars.filter { $0 != "\r" }.map { $0 == "\t" ? space : $0 }
    var wrapped: [String] = []
    for paragraph in scalars.split(separator: "\n", omittingEmptySubsequences: false) {
        var rest = paragraph
        while rest.count > columns {
            var end = rest.prefix(columns + 1).lastIndex(of: space).map { $0 - rest.startIndex } ?? 0
            if end <= 0 { end = columns }
            wrapped.append(String(String.UnicodeScalarView(rest.prefix(end))))
            rest = rest.dropFirst(end)
            if rest.first == space { rest = rest.dropFirst() }
        }
        wrapped.append(String(String.UnicodeScalarView(rest)))
    }
    return stride(from: 0, to: wrapped.count, by: lines).map {
        wrapped[$0..<min($0 + lines, wrapped.count)].joined(separator: "\n")
    }
}
