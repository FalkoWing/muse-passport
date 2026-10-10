import Foundation
import PassportOpus
import Testing
@testable import PassportBridge

@Suite struct SpeechTests {
    @Test func provenanceSkipsRepeatedCodeAndKeepsOriginalPositions() throws {
        let original = "正文。\n```\n重复正文。\n```\n**正文**。[正文](https://正文) 1️⃣。"
        let mapped = cleanSpeechMapped(original), raw = Array(original.unicodeScalars), points = Array(mapped.text.unicodeScalars)
        #expect(points.count == mapped.origins.count)
        for i in points.indices {
            #expect(points[i] == raw[mapped.origins[i]])
            if i > 0 { #expect(mapped.origins[i] > mapped.origins[i - 1]) }
        }
        let segments = speechSegments(original)
        #expect(segments[0].origin == 0)
        let start = try #require(original.range(of: "**正文**"))
        #expect(segments[1].origin == original[..<start.lowerBound].unicodeScalars.count + 2)
    }
    @Test func locatedFramesKeepFirstSamplesOriginAcrossSentenceBoundary() throws {
        let encoder = try SpeechEncoder()
        #expect(try encoder.feedLocated([Int16](repeating: 1, count: 400), origin: 17).isEmpty)
        let first = try encoder.feedLocated([Int16](repeating: 2, count: 1000), origin: 99)
        #expect(first.count == 1 && first[0].origin == 17)
        let tail = try encoder.feedLocated([], origin: .max, end: true)
        #expect(tail.count == 2 && tail.allSatisfy { $0.origin == 99 })
        let located = speechPacket(session: 7, frame: 0, kind: 5, opus: Data([99,0,0,0]) + first[0].opus)
        #expect(try BridgeFrames.packets(type: 14, id: 0, sequence: 1, body: located, mtu: 144).count == 1)
    }

    @Test func sharedCleaningCorpusPreservesReadableContent() throws {
        let url = try #require(Bundle.module.url(forResource: "speech_cleaning", withExtension: "tsv", subdirectory: "Fixtures"))
        func unescape(_ value: Substring) throws -> String {
            var out = "", iterator = value.makeIterator()
            while let character = iterator.next() {
                if character != "\\" { out.append(character); continue }
                let escaped = iterator.next()
                switch try #require(escaped) {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                default: throw SpeechFailure.format
                }
            }
            return out
        }
        for row in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !row.hasPrefix("#") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            #expect(fields.count == 3)
            #expect(cleanSpeechText(try unescape(fields[1])) == (try unescape(fields[2])), "Case: \(fields[0])")
        }
    }
    @Test func fixedRatePacketsDecodeAndFitOneBLEWrite() throws {
        let encoder = try SpeechEncoder()
        let decoder = try #require(passport_opus_decoder_create())
        defer { passport_opus_decoder_destroy(decoder) }
        var totalEnergy: Int64 = 0
        for frame in 0..<40 {
            let pcm = (0..<960).map { Int16(8000 * sin(Double(frame * 960 + $0) * .pi * 2 * 300 / 16000)) }
            let packets = try encoder.feed(pcm)
            #expect(packets.count == 1)
            let packet = try #require(packets.first)
            #expect(packet.count == 120)
            let wire = speechPacket(session: 7, frame: UInt32(frame), kind: 0, opus: packet)
            let ble = try BridgeFrames.packets(type: 14, id: 0, sequence: 1, body: wire, mtu: 247)
            #expect(ble.count == 1 && ble[0].count == 137)
            var output = [Int16](repeating: 0, count: 960)
            let decoded = Array(packet).withUnsafeBufferPointer { passport_opus_decode(decoder, $0.baseAddress, 120, &output) }
            #expect(decoded == 960)
            totalEnergy += output.reduce(Int64(0)) { $0 + Int64(abs(Int($1))) }
        }
        #expect(totalEnergy > 1_000_000)
        #expect(try encoder.feed([], end: true).count == 1)
        let silence = try SpeechEncoder().feed(Array(repeating: 0, count: 960))
        #expect(silence[0].count == 120)
    }
    @Test func cloudRequiresCompletionAndHandlesAnyChunkBoundary() throws {
        let source = Data(#"{"code":0,"message":"escaped \" }","data":"AAABAA=="}{"code":20000000,"data":null}"#.utf8)
        for size in [1,2,7,4096] {
            var parser = VolcSpeechParser(), audio = Data()
            for offset in stride(from: 0, to: source.count, by: size) {
                for part in try parser.feed(source.subdata(in: offset..<min(offset + size, source.count))) { audio += part }
            }
            try parser.finish()
            #expect(audio == Data([0,0,1,0]))
        }
        var incomplete = VolcSpeechParser()
        _ = try incomplete.feed(Data(#"{"code":0,"data":"AAABAA=="}"#.utf8))
        #expect(throws: SpeechFailure.self) { try incomplete.finish() }
        var error = VolcSpeechParser()
        #expect(throws: SpeechFailure.self) { try error.feed(Data(#"{"code":45000000}"#.utf8)) }
        var invalid = VolcSpeechParser()
        #expect(throws: SpeechFailure.self) { try invalid.feed(Data(#"{"code":0,"data":"%%%%"}"#.utf8)) }
    }
    @MainActor @Test func cloudNetworkBurstsFinishBeforeBLEPlaybackConsumesPCM() async throws {
        let expected = (0..<1920).map { Int16(8000 * sin(Double($0) * .pi * 2 * 300 / 16000)) }
        var bytes = Data()
        for sample in expected {
            bytes.append(UInt8(truncatingIfNeeded: sample))
            bytes.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: sample) >> 8))
        }
        func record(_ part: Data) -> Data {
            Data((#"{"code":0,"data":""# + part.base64EncodedString() + #""}"# + "\n").utf8)
        }
        let first = record(bytes.prefix(1921))
        let response = Array(first + record(bytes.dropFirst(1921)) + Data("{\"code\":20000000}\n".utf8))
        var offset = 0, downloadFinished = false, received: [Int16] = []
        let encoder = try SpeechEncoder()
        var packets: [Data] = []
        try await consumeCloudSpeechSentence(next: {
            if offset == response.count { downloadFinished = true; return nil }
            // Two network bursts, including a PCM sample split across them.
            // The network can resume independently of the paced BLE consumer.
            if offset == first.count { await Task.yield() }
            defer { offset += 1 }
            return response[offset]
        }, consume: { pcm in
            #expect(downloadFinished, "BLE playback must not wait for the next cloud network burst")
            received += pcm
            packets += try encoder.feed(pcm)
            await Task.yield() // the real caller may wait on device credit here
        })
        #expect(received == expected)
        #expect(packets.count == 2 && packets.allSatisfy { $0.count == 120 })
    }
    @MainActor @Test func cloudSentenceErrorsNeverReleasePartialPCM() async throws {
        for response in [
            "{\"code\":0,\"data\":\"AAABAA==\"}\n",
            "{\"code\":0,\"data\":\"AQ==\"}\n{\"code\":20000000}\n",
            "{\"code\":0,\"data\":\"AAABAA==\"}\n{\"code\":45000000}\n",
        ] {
            let bytes = Array(response.utf8)
            var offset = 0, consumed = false, failed = false
            do {
                try await consumeCloudSpeechSentence(next: {
                    guard offset < bytes.count else { return nil }
                    defer { offset += 1 }; return bytes[offset]
                }, consume: { _ in consumed = true })
            } catch is SpeechFailure { failed = true }
            #expect(failed && !consumed)
        }
    }
    @MainActor @Test func cloudSentenceReadCancellationReleasesNoPCM() async throws {
        let bytes = Array("{\"code\":0,\"data\":\"AAABAA==\"}\n".utf8)
        var offset = 0, consumed = false, cancelled = false
        do {
            try await consumeCloudSpeechSentence(next: {
                guard offset < bytes.count else { throw CancellationError() }
                defer { offset += 1 }; return bytes[offset]
            }, consume: { _ in consumed = true })
        } catch is CancellationError { cancelled = true }
        #expect(cancelled && !consumed)
    }
    @Test func speechUsesOnlyCompletedRepliesOfTheCurrentNote() throws {
        var cache = ReplyCache(); cache.begin(); cache.note("note")
        let delta = #"{"type":"event","event":"delta.text_append","payload":{"message_id":"r","parent_message_id":"note","text":"你好。"}}"#
        try cache.feed(Data((delta + "\n").utf8))
        #expect(cache.speechText(note: "note", message: "r") == nil)
        let done = #"{"type":"event","event":"delta.message_done","payload":{"message_id":"r","parent_message_id":"note"}}"#
        try cache.feed(Data((done + "\n").utf8))
        #expect(cache.speechText(note: "note", message: "r") == "你好。")
        #expect(cache.speechText(note: "old", message: "r") == nil)
        cache.begin(); cache.note("next")
        #expect(cache.speechText(note: "note", message: "r") == nil)
        let text = "第一句。第二句！" + String(repeating: "中", count: 180)
        let parts = speechSentences(text)
        #expect(parts.joined() == text && parts.allSatisfy { $0.count <= 80 })
    }
    @Test func sessionNumbersAndStatusAreLittleEndian() throws {
        let data = speechPacket(session: 0x12345678, frame: 0xAABBCCDD, kind: 4)
        #expect(Array(data) == [0x78,0x56,0x34,0x12,0xDD,0xCC,0xBB,0xAA,4])
        let status = try SpeechStatus(data)
        #expect(status.session == 0x12345678 && status.limit == 0xAABBCCDD && status.state == 4)
    }
    @Test func consecutivePunctuationStaysWithSpokenText() {
        for punctuation in ["！！！", "!!!", "？！", "……。", "；；"] {
            let before = "前面正常" + punctuation, after = "后面也应该继续。"
            #expect(speechSentences(before + after) == [before, after])
        }
        #expect(speechSentences("123！！！继续。") == ["123！！！", "继续。"])
        #expect(speechSentences("!!! ？！ *** ### —— …… \n").isEmpty)
    }
    @Test func sentenceLimitNeverSendsPunctuationOnlyToSynthesis() {
        for length in [79, 80, 159, 160] {
            let parts = speechSentences(String(repeating: "中", count: length) + "！！！后面继续。")
            #expect(parts.allSatisfy { $0.count <= 80 })
            #expect(parts.allSatisfy { part in
                part.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            })
            #expect(parts.joined().hasSuffix("后面继续。"))
            #expect(parts.joined().filter { $0 == "中" }.count == length)
        }
        let text = String(repeating: "中🙂", count: 81) + "！！！结束。"
        let parts = speechSentences(text)
        #expect(parts.allSatisfy { $0.count <= 80 })
        #expect(parts.joined() == text)
    }
    @Test func cleaningRemovesMarkupAndEmojiBeforeSegmentation() {
        #expect(cleanSpeechText("**加粗**和*斜体*") == "加粗和斜体")
        #expect(cleanSpeechText("# 标题\n正文") == "标题\n正文")
        #expect(cleanSpeechText("- 项目一\n- 项目二") == "项目一\n项目二")
        #expect(cleanSpeechText("1. 第一\n2. 第二") == "第一\n第二")
        #expect(cleanSpeechText("> 引用") == "引用")
        #expect(cleanSpeechText("见[文档](https://example.com/a?b=1)详情") == "见文档详情")
        #expect(cleanSpeechText("![图](https://x/y.png)说明") == "说明")
        #expect(cleanSpeechText("用 `idf.py build` 编译") == "用 idf.py build 编译")
        #expect(cleanSpeechText("开始\n```\nprint(1)\n```\n结束") == "开始\n\n结束")
        #expect(cleanSpeechText("太好了😀明天见") == "太好了明天见")
        #expect(cleanSpeechText("👨‍👩‍👧一家三口") == "一家三口")
        #expect(cleanSpeechText("---\n***\n___") == "\n\n")
        #expect(cleanSpeechText("esp_idf_v5 编译") == "esp_idf_v5 编译")
        #expect(cleanSpeechText("# 配置\n运行 `idf.py` **构建**，见[文档](http://x.cn)😀") == "配置\n运行 idf.py 构建，见文档")
        #expect(speechSentences(cleanSpeechText("😀😀😀")).isEmpty)
        #expect(speechSentences(cleanSpeechText("**重要**！！！后面继续。")) == ["重要！！！", "后面继续。"])
    }
}
