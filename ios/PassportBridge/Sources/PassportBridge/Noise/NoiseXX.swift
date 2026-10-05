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

// Ported to Swift from linux/src/musegadget/noise/noise_xx.py for Muse Passport
// community distribution, 2026-10-04. Uses CryptoKit for X25519, AES-GCM and
// HMAC-SHA256.

import CryptoKit
import Foundation

/// Raised when a Noise handshake or transport state machine is violated.
public struct NoiseError: Error, Equatable {
    public let reason: String
    init(_ reason: String) { self.reason = reason }
}

private let protocolName = "Noise_XX_25519_AESGCM_SHA256"
private let keyLength = 32
private let tagLength = 16
private let maxSafeNonce: UInt64 = (1 << 53) - 1

/// Public keys whose shared secret an attacker can predict.
let x25519LowOrderPoints: [[UInt8]] = {
    let tail = [UInt8](repeating: 0xFF, count: 30) + [0x7F]
    return [
        [UInt8](repeating: 0, count: 32),
        [1] + [UInt8](repeating: 0, count: 31),
        [0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE, 0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
         0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD, 0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00],
        [0x5F, 0x9C, 0x95, 0xBC, 0xA3, 0x50, 0x8C, 0x24, 0xB1, 0xD0, 0xB1, 0x55, 0x9C, 0x83, 0xEF, 0x5B,
         0x04, 0x44, 0x5C, 0xC4, 0x58, 0x1C, 0x8E, 0x86, 0xD8, 0x22, 0x4E, 0xDD, 0xD0, 0x9F, 0x11, 0x57],
        [0xEC] + tail, [0xED] + tail, [0xEE] + tail,
    ]
}()

private func hmacSHA256(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// The two-output HKDF of the Noise specification.
private func hkdf(_ chainingKey: [UInt8], _ inputKeyMaterial: [UInt8]) -> ([UInt8], [UInt8]) {
    let tempKey = hmacSHA256(chainingKey, inputKeyMaterial)
    let first = hmacSHA256(tempKey, [1])
    return (first, hmacSHA256(tempKey, first + [2]))
}

func x25519(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: [UInt8]) throws -> [UInt8] {
    guard publicKey.count == keyLength else { throw NoiseError("x25519: invalid public key length") }
    guard !x25519LowOrderPoints.contains(publicKey) else { throw NoiseError("x25519: rejected low-order public key") }
    guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
          let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes({ Array($0) }),
          shared.contains(where: { $0 != 0 }) else {
        throw NoiseError("x25519: DH produced all-zeros output")
    }
    return shared
}

/// AES-256-GCM with the Noise nonce: four zero bytes, then a big-endian counter.
struct CipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var poisoned = false

    init(key: [UInt8]? = nil) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    private mutating func nextNonce() throws -> AES.GCM.Nonce {
        guard !poisoned else { throw NoiseError("CipherState: poisoned after prior failure") }
        guard nonce < maxSafeNonce else {
            poisoned = true
            throw NoiseError("CipherState: nonce exhausted")
        }
        defer { nonce += 1 }
        let counter = (0..<8).map { UInt8(truncatingIfNeeded: nonce >> UInt64(8 * (7 - $0))) }
        return try AES.GCM.Nonce(data: [0, 0, 0, 0] + counter)
    }

    /// Without a key, as early in the handshake, the text passes through.
    mutating func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        guard let key else {
            guard !poisoned else { throw NoiseError("CipherState: poisoned after prior failure") }
            return plaintext
        }
        let nonce = try nextNonce()
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: ad) else {
            poisoned = true
            throw NoiseError("CipherState: encrypt failed")
        }
        return Array(sealed.ciphertext) + Array(sealed.tag)
    }

    mutating func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        guard let key else {
            guard !poisoned else { throw NoiseError("CipherState: poisoned after prior failure") }
            return ciphertext
        }
        let nonce = try nextNonce()
        guard ciphertext.count >= tagLength,
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(tagLength),
                                               tag: ciphertext.suffix(tagLength)),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: ad) else {
            poisoned = true
            throw NoiseError("CipherState: decrypt failed")
        }
        return Array(plaintext)
    }
}

struct SymmetricState {
    private var chainingKey: [UInt8]
    private(set) var handshakeHash: [UInt8]
    private var cipher = CipherState()

    init() {
        handshakeHash = Array(protocolName.utf8) + [UInt8](repeating: 0, count: 32 - protocolName.utf8.count)
        chainingKey = handshakeHash
        mixHash([])
    }

    mutating func mixHash(_ data: [UInt8]) {
        handshakeHash = Array(SHA256.hash(data: handshakeHash + data))
    }

    mutating func mixKey(_ inputKeyMaterial: [UInt8]) {
        let (next, key) = hkdf(chainingKey, inputKeyMaterial)
        chainingKey = next
        cipher = CipherState(key: key)
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws -> [UInt8] {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// The initiator sends with the first cipher and receives with the second.
    mutating func split() -> (CipherState, CipherState) {
        let (first, second) = hkdf(chainingKey, [])
        chainingKey = [UInt8](repeating: 0, count: 32)
        handshakeHash = chainingKey
        return (CipherState(key: first), CipherState(key: second))
    }
}

/// The client side of the Noise XX handshake with a Muse VM.
public struct NoiseXXInitiator {
    private enum Phase { case initialized, message1Sent, message2Read, message3Sent, split, dead }

    private var state = SymmetricState()
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: [UInt8] = []
    private var phase = Phase.initialized
    public private(set) var remoteStaticPublicKey: Data?

    /// Fresh keys for every session; tests pin them to reproduce the vectors.
    public init(ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                staticKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.ephemeral = ephemeral
        self.staticKey = staticKey
    }

    public var handshakeHash: Data { Data(state.handshakeHash) }

    private mutating func step<T>(from expected: Phase, to next: Phase, _ body: (inout Self) throws -> T) throws -> T {
        guard phase == expected else {
            throw NoiseError(phase == .dead ? "NoiseXX: called on dead handshake" : "NoiseXX: called in wrong phase")
        }
        do {
            let result = try body(&self)
            phase = next
            return result
        } catch {
            phase = .dead
            throw error
        }
    }

    public mutating func writeMessage1() throws -> Data {
        try step(from: .initialized, to: .message1Sent) { handshake in
            let publicKey = Array(handshake.ephemeral.publicKey.rawRepresentation)
            handshake.state.mixHash(publicKey)
            _ = try handshake.state.encryptAndHash([])
            return Data(publicKey)
        }
    }

    /// Returns the payload the VM attached to message 2.
    public mutating func readMessage2(_ message: Data) throws -> Data {
        try step(from: .message1Sent, to: .message2Read) { handshake in
            let bytes = [UInt8](message)
            guard bytes.count >= keyLength + (keyLength + tagLength) + tagLength else {
                throw NoiseError("NoiseXX: message 2 too short")
            }
            handshake.remoteEphemeral = Array(bytes[..<keyLength])
            handshake.state.mixHash(handshake.remoteEphemeral)
            handshake.state.mixKey(try x25519(handshake.ephemeral, handshake.remoteEphemeral))
            let staticEnd = keyLength + keyLength + tagLength
            let remoteStatic = try handshake.state.decryptAndHash(Array(bytes[keyLength..<staticEnd]))
            handshake.remoteStaticPublicKey = Data(remoteStatic)
            handshake.state.mixKey(try x25519(handshake.ephemeral, remoteStatic))
            return Data(try handshake.state.decryptAndHash(Array(bytes[staticEnd...])))
        }
    }

    public mutating func writeMessage3() throws -> Data {
        try step(from: .message2Read, to: .message3Sent) { handshake in
            let encryptedStatic = try handshake.state.encryptAndHash(Array(handshake.staticKey.publicKey.rawRepresentation))
            handshake.state.mixKey(try x25519(handshake.staticKey, handshake.remoteEphemeral))
            return Data(encryptedStatic + (try handshake.state.encryptAndHash([])))
        }
    }

    /// Ends the handshake and returns the encrypted transport.
    public mutating func split(chunkID: @escaping @Sendable () -> Int64 = { .random(in: .min ... .max) }) throws -> NoiseTransport {
        try step(from: .message3Sent, to: .split) { handshake in
            let (send, receive) = handshake.state.split()
            return NoiseTransport(send: send, receive: receive, chunkID: chunkID)
        }
    }
}
