import Foundation
import PassportOpus
import Testing
@testable import PassportBridge

@Suite struct SpeechTests {
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
}
