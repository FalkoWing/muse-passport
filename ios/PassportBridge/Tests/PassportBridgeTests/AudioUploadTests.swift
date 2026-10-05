import Foundation
import Testing
@testable import PassportBridge

@Suite struct AudioUploadTests {
    @Test func decodingMatchesTheReference() throws {
        let cases = try #require(try fixture("audio") as? [String: [[String: Any]]])
        #expect(!cases.isEmpty)
        for (name, steps) in cases {
            var upload = AudioUpload()
            for (index, step) in steps.enumerated() {
                let data = Data(hex: try #require(step["data"] as? String))
                let end = try #require(step["end"] as? Bool)
                if step["error"] != nil {
                    #expect(throws: AudioUploadError.self, "\(name) step \(index)") { try upload.feed(data, end: end) }
                } else {
                    let out = String(decoding: try upload.feed(data, end: end), as: UTF8.self)
                    #expect(out == step["out"] as? String, "\(name) step \(index)")
                }
            }
        }
    }

    @Test func requestBodyIsAStreamingWAV() throws {
        var upload = AudioUpload()
        let block = Data([0, 0, 0, 2, 0, 0, 0, 0, 0, 0x00])
        let text = String(decoding: AudioUpload.head + (try upload.feed(block, end: true)), as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let item = try #require((object["items"] as? [[String: Any]])?.first)
        let encoded = try #require(item["data_base64"] as? String)
        let wav = try #require(Data(base64Encoded: encoded))
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.count == 44 + 4)
        #expect(upload.samples == 2)
    }
}
