import CryptoKit
import Foundation
import Testing
@testable import PassportBridge

/// The deterministic payload the vector generator uses for large messages.
private func pattern(_ size: Int) -> [UInt8] { (0..<size).map { UInt8(($0 * 31 + 7) & 0xFF) } }

private func noiseFixture(_ section: String) throws -> Any {
    let root = try #require(try fixture("noise") as? [String: Any])
    return try #require(root[section])
}

/// Rebuilds a service frame from the generator's plain JSON description.
private func serviceFrame(_ description: [String: Any]) throws -> ServiceFrame {
    let stream = try #require(description["stream"] as? NSNumber).int64Value
    func headers() throws -> [NoiseHeader] {
        try #require(description["headers"] as? [[String]]).map { NoiseHeader($0[0], $0[1]) }
    }
    func body() throws -> [UInt8] { [UInt8](Data(hex: try #require(description["body"] as? String))) }
    func end() throws -> Bool { try #require(description["end"] as? Bool) }
    switch description["kind"] as? String {
    case "request":
        return ServiceFrame(streamID: stream, value: .request(
            verb: try #require(description["verb"] as? String), path: try #require(description["path"] as? String),
            headers: try headers(), body: try body(), end: try end()))
    case "response":
        return ServiceFrame(streamID: stream, value: .response(
            status: try #require(description["status"] as? NSNumber).int32Value,
            headers: try headers(), body: try body(), end: try end()))
    case "body_chunk":
        return ServiceFrame(streamID: stream, value: .bodyChunk(try body(), end: try end()))
    case "reset":
        return ServiceFrame(streamID: stream, value: .reset(
            code: try #require(description["code"] as? NSNumber).int32Value,
            reason: try #require(description["reason"] as? String)))
    default:
        return ServiceFrame(streamID: stream)
    }
}

/// Hands out the generator's pinned chunk ids: 1001, 1002, ...
private final class ChunkIDs: @unchecked Sendable {
    private var next: Int64 = 1000
    func callAsFunction() -> Int64 {
        next += 1
        return next
    }
}

@Suite struct EnvelopeTests {
    @Test func framesEncodeAndDecodeLikeTheReference() throws {
        let envelope = try #require(try noiseFixture("envelope") as? [String: Any])
        let frames = try #require(envelope["frames"] as? [[String: Any]])
        #expect(frames.count > 10)
        for item in frames {
            let hex = try #require(item["hex"] as? String)
            let frame = try serviceFrame(try #require(item["frame"] as? [String: Any]))
            #expect(Data(frame.encoded()).hex == hex)
            #expect(try ServiceFrame(decoding: [UInt8](Data(hex: hex))) == frame)
        }
    }

    @Test func unknownFieldsAreSkippedAndTheLastKindWins() throws {
        let envelope = try #require(try noiseFixture("envelope") as? [String: Any])
        let cases = try #require(envelope["lenient"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let hex = try #require(item["hex"] as? String)
            let expected = try serviceFrame(try #require(item["frame"] as? [String: Any]))
            #expect(try ServiceFrame(decoding: [UInt8](Data(hex: hex))) == expected, "\(hex)")
        }
    }

    @Test func malformedFramesAreRejected() throws {
        let envelope = try #require(try noiseFixture("envelope") as? [String: Any])
        let cases = try #require(envelope["bad"] as? [String])
        #expect(!cases.isEmpty)
        for hex in cases {
            #expect(throws: ProtoError.self, "\(hex)") { try ServiceFrame(decoding: [UInt8](Data(hex: hex))) }
        }
    }

    @Test func serviceWrappersMatchTheReference() throws {
        let envelope = try #require(try noiseFixture("envelope") as? [String: Any])
        for item in try #require(envelope["wrappers"] as? [[String: String]]) {
            let payload = [UInt8](Data(hex: try #require(item["payload"])))
            let request = try #require(item["request"]), response = try #require(item["response"])
            #expect(Data(encodeServiceRequest(payload)).hex == request)
            #expect(Data(encodeServiceResponse(payload)).hex == response)
            #expect(try decodeServiceRequest([UInt8](Data(hex: request))) == payload)
            #expect(try decodeServiceResponse([UInt8](Data(hex: response))) == payload)
        }
    }
}

@Suite struct NoiseFramingTests {
    @Test func chunkingMatchesTheReferenceAndReassembles() throws {
        let cases = try #require(try noiseFixture("noise_frames") as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let size = try #require(item["size"] as? Int)
            let chunkID = try #require(item["chunk_id"] as? NSNumber).int64Value
            let expected = try #require(item["frames"] as? [[String: Any]])
            let frames = try encodeNoiseFrames(pattern(size), chunkID: chunkID)
            #expect(frames.map(\.count) == expected.map { $0["length"] as? Int }, "\(size) bytes")
            #expect(frames.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                    == expected.map { $0["sha256"] as? String }, "\(size) bytes")

            var decoder = NoiseFrameDecoder()
            var whole: [UInt8]?
            for frame in frames.reversed() { whole = try decoder.decode(frame) }
            #expect(whole == pattern(size))
        }
    }

    @Test func rejectsDuplicatesMismatchesAndFloods() throws {
        let two = try encodeNoiseFrames(pattern(70000), chunkID: 5)
        var decoder = NoiseFrameDecoder()
        #expect(try decoder.decode(two[0]) == nil)
        #expect(throws: NoiseFramingError.self) { try decoder.decode(two[0]) }
        // Poisoned: even a good frame is refused afterwards.
        #expect(throws: NoiseFramingError.self) { try decoder.decode(two[1]) }

        decoder = NoiseFrameDecoder()
        #expect(try decoder.decode(two[0]) == nil)
        let mismatch = NoiseTransportFrame(chunkID: 5, chunkIndex: 1, totalChunks: 3, payload: [1]).encoded()
        #expect(throws: NoiseFramingError.self) { try decoder.decode(mismatch) }

        decoder = NoiseFrameDecoder()
        for id in 0..<16 {
            #expect(try decoder.decode(NoiseTransportFrame(chunkID: Int64(id), totalChunks: 2, payload: [1]).encoded()) == nil)
        }
        #expect(throws: NoiseFramingError.self) {
            try decoder.decode(NoiseTransportFrame(chunkID: 99, totalChunks: 2, payload: [1]).encoded())
        }

        decoder = NoiseFrameDecoder()
        #expect(throws: NoiseFramingError.self) {
            try decoder.decode(NoiseTransportFrame(chunkIndex: 2, totalChunks: 2).encoded())
        }
        #expect(throws: NoiseFramingError.self) { try encodeNoiseFrames([UInt8](repeating: 0, count: 65489 * 256 + 1), chunkID: 1) }
    }
}

@Suite struct NoiseHandshakeTests {
    private func pinnedInitiator(_ vector: [String: Any]) throws -> NoiseXXInitiator {
        let keys = try #require(vector["keys"] as? [String: String])
        return NoiseXXInitiator(
            ephemeral: try .init(rawRepresentation: Data(hex: try #require(keys["initiator_ephemeral"]))),
            staticKey: try .init(rawRepresentation: Data(hex: try #require(keys["initiator_static"]))))
    }

    @Test func handshakeAndTransportMatchTheReferenceByteForByte() throws {
        let vector = try #require(try noiseFixture("handshake") as? [String: Any])
        var initiator = try pinnedInitiator(vector)
        #expect(try initiator.writeMessage1().hex == vector["message1"] as? String)
        let payload = try initiator.readMessage2(Data(hex: try #require(vector["message2"] as? String)))
        #expect(payload.hex == vector["payload"] as? String)
        #expect(initiator.remoteStaticPublicKey?.hex == vector["remote_static"] as? String)
        #expect(try initiator.writeMessage3().hex == vector["message3"] as? String)
        #expect(initiator.handshakeHash.hex == vector["handshake_hash"] as? String)

        let chunkIDs = ChunkIDs()
        var transport = try initiator.split(chunkID: { chunkIDs() })
        let events = try #require(vector["events"] as? [[String: Any]])
        #expect(events.count > 10)
        for (index, event) in events.enumerated() {
            let cipher = try #require(event["cipher"] as? [String])
            let description = event["frame"] as? [String: Any]
            let label: Comment = "event \(index)"
            if event["from"] as? String == "vm" {
                var decoded: DecryptedFrame?
                for part in cipher { decoded = try transport.decryptFrame(Data(hex: part)) }
                guard let description else {
                    #expect(decoded == nil, label)
                    continue
                }
                let expected = try serviceFrame(description)
                switch expected.value {
                case let .response(status, headers, body, end):
                    #expect(decoded == DecryptedFrame(streamID: expected.streamID, frame: .response(
                        status: status, headers: headers, body: Data(body), end: end)), label)
                case let .bodyChunk(data, end):
                    #expect(decoded == DecryptedFrame(streamID: expected.streamID, frame: .bodyChunk(Data(data), end: end)), label)
                case let .reset(code, reason):
                    #expect(decoded == DecryptedFrame(streamID: expected.streamID, frame: .reset(code: code, reason: reason)), label)
                default:
                    Issue.record("unexpected vector kind", sourceLocation: #_sourceLocation)
                }
                continue
            }
            let frame = try serviceFrame(try #require(description))
            let produced: [Data]
            switch (try #require(event["call"] as? String), frame.value) {
            case let ("start", .request(verb, path, headers, _, _)):
                let result = try transport.startStreamRequest(verb, path, headers: headers)
                #expect(result.streamID == frame.streamID, label)
                produced = result.frames
            case let ("request", .request(verb, path, headers, body, _)):
                let result = try transport.encryptHTTPRequest(verb, path, body: Data(body), headers: headers)
                #expect(result.streamID == frame.streamID, label)
                produced = result.frames
            case let ("chunk", .bodyChunk(data, end)):
                produced = try transport.encryptBodyChunk(streamID: frame.streamID, Data(data), endBody: end)
            case ("reset", .reset):
                produced = try transport.encryptReset(streamID: frame.streamID)
            default:
                Issue.record("unexpected vector call", sourceLocation: #_sourceLocation)
                continue
            }
            #expect(produced.map(\.hex) == cipher, label)
        }
    }

    @Test func lowOrderPublicKeysAreRejected() throws {
        let vector = try #require(try noiseFixture("handshake") as? [String: Any])
        let points = try #require(vector["low_order_points"] as? [String])
        #expect(points.count == 7)
        #expect(points == x25519LowOrderPoints.map { Data($0).hex })
        for point in points {
            var initiator = NoiseXXInitiator()
            _ = try initiator.writeMessage1()
            #expect(throws: NoiseError.self) { try initiator.readMessage2(Data(hex: point) + Data(count: 64)) }
            // A failed handshake stays dead.
            #expect(throws: NoiseError.self) { try initiator.writeMessage3() }
        }
    }

    @Test func tamperingKillsTheHandshakeAndTheTransport() throws {
        let vector = try #require(try noiseFixture("handshake") as? [String: Any])
        var message2 = Data(hex: try #require(vector["message2"] as? String))
        var initiator = try pinnedInitiator(vector)
        _ = try initiator.writeMessage1()
        message2[40] ^= 1
        #expect(throws: NoiseError.self) { try initiator.readMessage2(message2) }
        #expect(throws: NoiseError.self) { try initiator.writeMessage1() }

        initiator = try pinnedInitiator(vector)
        #expect(throws: NoiseError.self) { try initiator.readMessage2(Data(count: 96)) }

        initiator = try pinnedInitiator(vector)
        _ = try initiator.writeMessage1()
        _ = try initiator.readMessage2(Data(hex: try #require(vector["message2"] as? String)))
        _ = try initiator.writeMessage3()
        var transport = try initiator.split()
        #expect(throws: NoiseError.self) { try transport.decryptFrame(Data(count: 40)) }
        #expect(throws: NoiseError.self) { try transport.startStreamRequest("POST", "/link-control") }
    }
}
