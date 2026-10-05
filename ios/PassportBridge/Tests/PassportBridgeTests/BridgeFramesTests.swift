import Foundation
import Testing
@testable import PassportBridge

@Suite struct BridgeFramesTests {
    @Test func packetsMatchTheAndroidImplementation() throws {
        let cases = try #require(try fixture("frames") as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let body = Data(hex: try #require(item["body"] as? String))
            let mtu = try #require(item["mtu"] as? Int)
            let packets = try BridgeFrames.packets(type: 5, id: 42, sequence: 65535, body: body, mtu: mtu)
            #expect(packets.map(\.hex) == item["packets"] as? [String], "mtu \(mtu), \(body.count) bytes")

            var frames = BridgeFrames()
            var message: BridgeMessage?
            for packet in packets { message = try frames.feed(packet) }
            #expect(message == BridgeMessage(type: 5, id: 42, sequence: 65535, body: body))
        }
    }

    @Test func rejectsGapsDuplicatesAndBadHeaders() throws {
        let packets = try BridgeFrames.packets(type: 5, id: 42, sequence: 123, body: Data(count: 800), mtu: 247)
        var frames = BridgeFrames()
        _ = try frames.feed(packets[0])
        #expect(throws: BridgeFrameError.order) { try frames.feed(packets[2]) }

        frames = BridgeFrames()
        _ = try frames.feed(packets[0])
        #expect(throws: BridgeFrameError.overlap) { try frames.feed(packets[0]) }

        frames = BridgeFrames()
        var malformed = packets[0]
        malformed[6] = 1
        #expect(throws: BridgeFrameError.overlap) { try frames.feed(malformed) }
        #expect(throws: BridgeFrameError.header) { try frames.feed(Data(count: 7)) }
        #expect(throws: BridgeFrameError.header) { try frames.feed(Data([5, 4, 0, 0, 0, 0, 0, 0])) }
        // A continuation with nothing started.
        #expect(throws: BridgeFrameError.order) { try frames.feed(packets[1]) }
    }

    @Test func rejectsOversizedMessagesAndTinyLinks() {
        #expect(throws: BridgeFrameError.size) {
            try BridgeFrames.packets(type: 5, id: 1, sequence: 1, body: Data(count: 8193), mtu: 247)
        }
        #expect(throws: BridgeFrameError.size) {
            try BridgeFrames.packets(type: 5, id: 1, sequence: 1, body: Data(), mtu: 22)
        }
    }

    @Test func recoversAfterAnError() throws {
        let packets = try BridgeFrames.packets(type: 7, id: 9, sequence: 2, body: Data([1, 2, 3]), mtu: 23)
        var frames = BridgeFrames()
        #expect(throws: BridgeFrameError.order) { try frames.feed(Data([7, 0, 9, 0, 2, 0, 0, 0])) }
        #expect(try frames.feed(packets[0]) == BridgeMessage(type: 7, id: 9, sequence: 2, body: Data([1, 2, 3])))
    }
}
