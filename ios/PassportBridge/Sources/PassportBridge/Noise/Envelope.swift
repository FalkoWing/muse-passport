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

// Ported to Swift from linux/src/musegadget/noise/envelope.py for Muse
// Passport community distribution, 2026-10-04.

import Foundation

public struct NoiseHeader: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// The one-of carried by a service frame.
enum ServiceFrameValue: Equatable, Sendable {
    case request(verb: String, path: String, headers: [NoiseHeader], body: [UInt8], end: Bool)
    case response(status: Int32, headers: [NoiseHeader], body: [UInt8], end: Bool)
    case bodyChunk([UInt8], end: Bool)
    case reset(code: Int32, reason: String)
}

struct ServiceFrame: Equatable, Sendable {
    var streamID: Int64 = 0
    var value: ServiceFrameValue?

    func encoded() -> [UInt8] {
        var out = ProtoWriter()
        if streamID != 0 { out.int64Field(1, streamID) }
        var inner = ProtoWriter()
        switch value {
        case nil:
            return out.bytes
        case let .request(verb, path, headers, body, end):
            if !verb.isEmpty { inner.stringField(1, verb) }
            if !path.isEmpty { inner.stringField(2, path) }
            for header in headers { inner.bytesField(3, Self.encoded(header)) }
            if !body.isEmpty { inner.bytesField(4, body) }
            if end { inner.boolField(5, true) }
            out.bytesField(2, inner.bytes)
        case let .response(status, headers, body, end):
            if status != 0 { inner.int32Field(1, status) }
            for header in headers { inner.bytesField(2, Self.encoded(header)) }
            if !body.isEmpty { inner.bytesField(3, body) }
            if end { inner.boolField(4, true) }
            out.bytesField(3, inner.bytes)
        case let .bodyChunk(data, end):
            if !data.isEmpty { inner.bytesField(1, data) }
            if end { inner.boolField(2, true) }
            out.bytesField(4, inner.bytes)
        case let .reset(code, reason):
            if code != 0 { inner.int32Field(1, code) }
            if !reason.isEmpty { inner.stringField(2, reason) }
            out.bytesField(5, inner.bytes)
        }
        return out.bytes
    }

    private static func encoded(_ header: NoiseHeader) -> [UInt8] {
        var out = ProtoWriter()
        if !header.key.isEmpty { out.stringField(1, header.key) }
        if !header.value.isEmpty { out.stringField(2, header.value) }
        return out.bytes
    }

    init(streamID: Int64 = 0, value: ServiceFrameValue? = nil) {
        self.streamID = streamID
        self.value = value
    }

    init(decoding data: [UInt8]) throws {
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: streamID = Int64(bitPattern: try reader.varint(wire, "ServiceFrame.stream_id"))
            case 2: value = try Self.request(try reader.delimited(wire, "ServiceFrame.request"))
            case 3: value = try Self.response(try reader.delimited(wire, "ServiceFrame.response"))
            case 4: value = try Self.bodyChunk(try reader.delimited(wire, "ServiceFrame.body_chunk"))
            case 5: value = try Self.reset(try reader.delimited(wire, "ServiceFrame.reset"))
            default: try reader.skip(wire)
            }
        }
    }

    private static func header(_ data: [UInt8]) throws -> NoiseHeader {
        var header = NoiseHeader("", "")
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: header.key = try reader.string(wire, "Header.key")
            case 2: header.value = try reader.string(wire, "Header.value")
            default: try reader.skip(wire)
            }
        }
        return header
    }

    private static func request(_ data: [UInt8]) throws -> ServiceFrameValue {
        var verb = "", path = "", headers: [NoiseHeader] = [], body: [UInt8] = [], end = false
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: verb = try reader.string(wire, "ApplicationRequest.verb")
            case 2: path = try reader.string(wire, "ApplicationRequest.path")
            case 3: headers.append(try header(try reader.delimited(wire, "ApplicationRequest.headers")))
            case 4: body = try reader.delimited(wire, "ApplicationRequest.body")
            case 5: end = try reader.varint(wire, "ApplicationRequest.end_body") != 0
            default: try reader.skip(wire)
            }
        }
        return .request(verb: verb, path: path, headers: headers, body: body, end: end)
    }

    private static func response(_ data: [UInt8]) throws -> ServiceFrameValue {
        var status: Int32 = 0, headers: [NoiseHeader] = [], body: [UInt8] = [], end = false
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: status = try reader.int32(wire, "ApplicationResponse.status")
            case 2: headers.append(try header(try reader.delimited(wire, "ApplicationResponse.headers")))
            case 3: body = try reader.delimited(wire, "ApplicationResponse.body")
            case 4: end = try reader.varint(wire, "ApplicationResponse.end_body") != 0
            default: try reader.skip(wire)
            }
        }
        return .response(status: status, headers: headers, body: body, end: end)
    }

    private static func bodyChunk(_ data: [UInt8]) throws -> ServiceFrameValue {
        var chunk: [UInt8] = [], end = false
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: chunk = try reader.delimited(wire, "BodyChunk.data")
            case 2: end = try reader.varint(wire, "BodyChunk.end_body") != 0
            default: try reader.skip(wire)
            }
        }
        return .bodyChunk(chunk, end: end)
    }

    private static func reset(_ data: [UInt8]) throws -> ServiceFrameValue {
        var code: Int32 = 0, reason = ""
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1:
                code = try reader.int32(wire, "Reset.code")
                // Unspecified, cancelled, timeout, protocol error, refused
                // stream, internal error, service unavailable.
                guard (0...6).contains(code) else { throw ProtoError("unknown reset code") }
            case 2: reason = try reader.string(wire, "Reset.reason")
            default: try reader.skip(wire)
            }
        }
        return .reset(code: code, reason: reason)
    }
}

/// The request wrapper addressed to the daemon service, the only one this
/// client talks to; the daemon is the default and is not written out.
func encodeServiceRequest(_ payload: [UInt8]) -> [UInt8] {
    var out = ProtoWriter()
    if !payload.isEmpty { out.bytesField(2, payload) }
    return out.bytes
}

func decodeServiceRequest(_ data: [UInt8]) throws -> [UInt8] {
    var payload: [UInt8] = []
    var reader = ProtoReader(data)
    while !reader.isAtEnd {
        let (field, wire) = try reader.key()
        switch field {
        case 1:
            guard try reader.varint(wire, "ServiceRequest.service") <= 3 else { throw ProtoError("unknown service type") }
        case 2: payload = try reader.delimited(wire, "ServiceRequest.payload")
        default: try reader.skip(wire)
        }
    }
    return payload
}

func encodeServiceResponse(_ payload: [UInt8]) -> [UInt8] {
    var out = ProtoWriter()
    if !payload.isEmpty { out.bytesField(1, payload) }
    return out.bytes
}

func decodeServiceResponse(_ data: [UInt8]) throws -> [UInt8] {
    var payload: [UInt8] = []
    var reader = ProtoReader(data)
    while !reader.isAtEnd {
        let (field, wire) = try reader.key()
        switch field {
        case 1: payload = try reader.delimited(wire, "ServiceResponse.payload")
        default: try reader.skip(wire)
        }
    }
    return payload
}
