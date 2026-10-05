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

// Ported to Swift from linux/src/musegadget/noise/_proto.py for Muse Passport
// community distribution, 2026-10-04.

/// Raised when a Noise protobuf message is malformed.
struct ProtoError: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

enum Wire {
    static let varint = 0, fixed64 = 1, delimited = 2, fixed32 = 5
}

struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var value = value
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            bytes.append(value != 0 ? byte | 0x80 : byte)
        } while value != 0
    }

    private mutating func key(_ field: UInt64, _ wire: Int) { varint(field << 3 | UInt64(wire)) }

    mutating func varintField(_ field: UInt64, _ value: UInt64) {
        key(field, Wire.varint)
        varint(value)
    }

    mutating func int64Field(_ field: UInt64, _ value: Int64) { varintField(field, UInt64(bitPattern: value)) }
    mutating func int32Field(_ field: UInt64, _ value: Int32) { varintField(field, UInt64(bitPattern: Int64(value))) }
    mutating func uint32Field(_ field: UInt64, _ value: UInt32) { varintField(field, UInt64(value)) }
    mutating func boolField(_ field: UInt64, _ value: Bool) { varintField(field, value ? 1 : 0) }

    mutating func bytesField(_ field: UInt64, _ value: [UInt8]) {
        key(field, Wire.delimited)
        varint(UInt64(value.count))
        bytes += value
    }

    mutating func stringField(_ field: UInt64, _ value: String) { bytesField(field, Array(value.utf8)) }
}

struct ProtoReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { throw ProtoError("truncated varint") }
            let byte = bytes[offset]
            offset += 1
            if index == 9, byte & 0xFE != 0 { throw ProtoError("malformed varint") }
            value |= UInt64(byte & 0x7F) << UInt64(7 * index)
            if byte & 0x80 == 0 { return value }
        }
        throw ProtoError("malformed varint")
    }

    mutating func key() throws -> (field: UInt64, wire: Int) {
        let key = try varint()
        let field = key >> 3, wire = Int(key & 7)
        guard field != 0, field <= (1 << 29) - 1, !(19000...19999).contains(field) else {
            throw ProtoError("invalid field number")
        }
        guard [Wire.varint, Wire.fixed64, Wire.delimited, Wire.fixed32].contains(wire) else {
            throw ProtoError("invalid wire type")
        }
        return (field, wire)
    }

    mutating func delimited() throws -> [UInt8] {
        let length = try varint()
        guard length <= UInt64(bytes.count - offset) else { throw ProtoError("truncated delimited field") }
        defer { offset += Int(length) }
        return Array(bytes[offset..<offset + Int(length)])
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case Wire.varint: _ = try varint()
        case Wire.delimited: _ = try delimited()
        case Wire.fixed64, Wire.fixed32:
            let width = wire == Wire.fixed64 ? 8 : 4
            guard offset + width <= bytes.count else { throw ProtoError("truncated fixed field") }
            offset += width
        default: throw ProtoError("invalid wire type")
        }
    }

    // Typed reads for a known field; a wrong wire type is an error.

    mutating func varint(_ wire: Int, _ name: String) throws -> UInt64 {
        guard wire == Wire.varint else { throw ProtoError("\(name) wrong wire type") }
        return try varint()
    }

    mutating func delimited(_ wire: Int, _ name: String) throws -> [UInt8] {
        guard wire == Wire.delimited else { throw ProtoError("\(name) wrong wire type") }
        return try delimited()
    }

    mutating func string(_ wire: Int, _ name: String) throws -> String {
        guard let text = String(validating: try delimited(wire, name), as: UTF8.self) else {
            throw ProtoError("invalid utf-8 string")
        }
        return text
    }

    mutating func int32(_ wire: Int, _ name: String) throws -> Int32 {
        guard let value = Int32(exactly: Int64(bitPattern: try varint(wire, name))) else {
            throw ProtoError("int32 value out of range")
        }
        return value
    }

    mutating func uint32(_ wire: Int, _ name: String) throws -> UInt32 {
        guard let value = UInt32(exactly: try varint(wire, name)) else { throw ProtoError("uint32 value out of range") }
        return value
    }
}
