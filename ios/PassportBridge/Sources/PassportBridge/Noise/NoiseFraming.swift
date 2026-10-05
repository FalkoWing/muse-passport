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

// Ported to Swift from linux/src/musegadget/noise/framing.py for Muse Passport
// community distribution, 2026-10-04.

import Foundation

let maxChunkPayload = 65489
let maxPendingAssemblies = 16
let maxTotalChunks = 256
let maxAssemblyBytes = 16 * 1024 * 1024
let assemblyLifetime: TimeInterval = 60

struct NoiseFramingError: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

struct NoiseTransportFrame: Equatable {
    var chunkID: Int64 = 0
    var chunkIndex: UInt32 = 0
    var totalChunks: UInt32 = 1
    var payload: [UInt8] = []

    func encoded() -> [UInt8] {
        var out = ProtoWriter()
        if chunkID != 0 { out.int64Field(1, chunkID) }
        if chunkIndex != 0 { out.uint32Field(2, chunkIndex) }
        if totalChunks != 0 { out.uint32Field(3, totalChunks) }
        if !payload.isEmpty { out.bytesField(4, payload) }
        return out.bytes
    }

    init(chunkID: Int64 = 0, chunkIndex: UInt32 = 0, totalChunks: UInt32 = 1, payload: [UInt8] = []) {
        self.chunkID = chunkID
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.payload = payload
    }

    init(decoding data: [UInt8]) throws {
        var reader = ProtoReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: chunkID = Int64(bitPattern: try reader.varint(wire, "NoiseTransportFrame.chunk_id"))
            case 2: chunkIndex = try reader.uint32(wire, "NoiseTransportFrame.chunk_index")
            case 3: totalChunks = try reader.uint32(wire, "NoiseTransportFrame.total_chunks")
            case 4: payload = try reader.delimited(wire, "NoiseTransportFrame.payload")
            default: try reader.skip(wire)
            }
        }
    }
}

/// Splits one message into frames that each fit a Noise transport message.
func encodeNoiseFrames(_ payload: [UInt8], chunkID: Int64) throws -> [[UInt8]] {
    let total = max(1, (payload.count + maxChunkPayload - 1) / maxChunkPayload)
    guard total <= maxTotalChunks else { throw NoiseFramingError("payload too large for noise framing") }
    return (0..<total).map { index in
        let start = index * maxChunkPayload
        return NoiseTransportFrame(chunkID: chunkID, chunkIndex: UInt32(index), totalChunks: UInt32(total),
                                   payload: Array(payload[start..<min(start + maxChunkPayload, payload.count)])).encoded()
    }
}

struct NoiseFrameDecoder {
    private struct Assembly {
        var chunks: [UInt32: [UInt8]] = [:]
        var total: UInt32
        var totalBytes = 0
        var created: Date
    }

    private var pending: [Int64: Assembly] = [:]
    private var poisoned = false

    /// Returns the reassembled message once its last chunk arrives.
    mutating func decode(_ data: [UInt8]) throws -> [UInt8]? {
        guard !poisoned else { throw NoiseFramingError("NoiseFrameDecoder: poisoned after prior failure") }
        do {
            return try accept(try NoiseTransportFrame(decoding: data))
        } catch {
            poisoned = true
            throw error
        }
    }

    private mutating func accept(_ frame: NoiseTransportFrame) throws -> [UInt8]? {
        guard frame.totalChunks >= 1, frame.totalChunks <= maxTotalChunks else {
            throw NoiseFramingError("invalid totalChunks")
        }
        guard frame.chunkIndex < frame.totalChunks else { throw NoiseFramingError("chunkIndex out of range") }
        guard frame.payload.count <= maxChunkPayload else { throw NoiseFramingError("payload too large for noise frame") }
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.created) <= assemblyLifetime }
        if pending[frame.chunkID] == nil {
            guard pending.count < maxPendingAssemblies else {
                throw NoiseFramingError("too many pending noise frame assemblies")
            }
            pending[frame.chunkID] = Assembly(total: frame.totalChunks, created: now)
        }
        guard var assembly = pending.removeValue(forKey: frame.chunkID), assembly.total == frame.totalChunks else {
            throw NoiseFramingError("inconsistent totalChunks for chunkId")
        }
        guard assembly.chunks[frame.chunkIndex] == nil else { throw NoiseFramingError("duplicate chunkIndex") }
        assembly.totalBytes += frame.payload.count
        guard assembly.totalBytes <= maxAssemblyBytes else { throw NoiseFramingError("assembly exceeded byte budget") }
        assembly.chunks[frame.chunkIndex] = frame.payload
        guard assembly.chunks.count == Int(assembly.total) else {
            pending[frame.chunkID] = assembly
            return nil
        }
        return (0..<assembly.total).flatMap { assembly.chunks[$0] ?? [] }
    }
}
