// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported to Swift from linux/src/musegadget/noise/transport.py for Muse
// Passport community distribution, 2026-10-04.

import Foundation

/// What the VM sent on one stream.
public enum NoiseFrame: Equatable, Sendable {
    case response(status: Int32, headers: [NoiseHeader], body: Data, end: Bool)
    case bodyChunk(Data, end: Bool)
    case reset(code: Int32, reason: String)
}

public struct DecryptedFrame: Equatable, Sendable {
    public var streamID: Int64
    public var frame: NoiseFrame
}

public struct EncryptedFrames: Equatable, Sendable {
    public var streamID: Int64
    public var frames: [Data]
}

/// HTTP-like requests over the encrypted Noise channel. Any failure kills the
/// transport: the cipher nonces can no longer be trusted to line up.
public struct NoiseTransport: Sendable {
    /// The reset code a client uses to abandon a stream.
    public static let cancelled: Int32 = 1

    private var send: CipherState
    private var receive: CipherState
    private var decoder = NoiseFrameDecoder()
    private var nextStreamID: Int64 = 1
    private var dead = false
    private let chunkID: @Sendable () -> Int64

    init(send: CipherState, receive: CipherState, chunkID: @escaping @Sendable () -> Int64) {
        self.send = send
        self.receive = receive
        self.chunkID = chunkID
    }

    private mutating func guarded<T>(_ body: (inout Self) throws -> T) throws -> T {
        guard !dead else { throw NoiseError("NoiseTransport: dead after prior failure") }
        do {
            return try body(&self)
        } catch {
            dead = true
            throw error
        }
    }

    private mutating func encrypt(_ frame: ServiceFrame) throws -> [Data] {
        try encodeNoiseFrames(encodeServiceRequest(frame.encoded()), chunkID: chunkID()).map {
            Data(try send.encrypt(ad: [], $0))
        }
    }

    private mutating func request(_ method: String, _ path: String, _ headers: [NoiseHeader], _ body: Data,
                                  end: Bool) throws -> EncryptedFrames {
        try guarded { transport in
            let streamID = transport.nextStreamID
            transport.nextStreamID += 1
            let frame = ServiceFrame(streamID: streamID, value: .request(
                verb: method, path: path, headers: headers, body: [UInt8](body), end: end))
            return EncryptedFrames(streamID: streamID, frames: try transport.encrypt(frame))
        }
    }

    /// A complete request: the body ends with it.
    public mutating func encryptHTTPRequest(_ method: String, _ path: String, body: Data = Data(),
                                            headers: [NoiseHeader] = []) throws -> EncryptedFrames {
        try request(method, path, headers, body, end: true)
    }

    /// A request whose body follows in chunks.
    public mutating func startStreamRequest(_ method: String, _ path: String,
                                            headers: [NoiseHeader] = []) throws -> EncryptedFrames {
        try request(method, path, headers, Data(), end: false)
    }

    public mutating func encryptBodyChunk(streamID: Int64, _ data: Data, endBody: Bool = false) throws -> [Data] {
        try guarded { try $0.encrypt(ServiceFrame(streamID: streamID, value: .bodyChunk([UInt8](data), end: endBody))) }
    }

    public mutating func encryptReset(streamID: Int64, reason: String = "") throws -> [Data] {
        try guarded {
            try $0.encrypt(ServiceFrame(streamID: streamID, value: .reset(code: Self.cancelled, reason: reason)))
        }
    }

    /// Returns nil until a chunked frame is complete, or for a frame of no known kind.
    public mutating func decryptFrame(_ ciphertext: Data) throws -> DecryptedFrame? {
        try guarded { transport in
            let plain = try transport.receive.decrypt(ad: [], [UInt8](ciphertext))
            guard let reassembled = try transport.decoder.decode(plain) else { return nil }
            let payload = try decodeServiceResponse(reassembled)
            guard !payload.isEmpty else { throw NoiseError("empty ServiceResponse payload") }
            let frame = try ServiceFrame(decoding: payload)
            switch frame.value {
            case let .response(status, headers, body, end):
                return DecryptedFrame(streamID: frame.streamID,
                                      frame: .response(status: status, headers: headers, body: Data(body), end: end))
            case let .bodyChunk(data, end):
                return DecryptedFrame(streamID: frame.streamID, frame: .bodyChunk(Data(data), end: end))
            case let .reset(code, reason):
                return DecryptedFrame(streamID: frame.streamID, frame: .reset(code: code, reason: reason))
            case .request:
                throw NoiseError("NoiseTransport: unexpected request frame from server")
            case nil:
                return nil
            }
        }
    }
}
