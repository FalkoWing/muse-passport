import CryptoKit
import Foundation
@testable import PassportBridge

/// An ordered, awaitable queue. `next` gives up after a short wait so a
/// missing message fails a test instead of hanging it.
actor Mailbox<Item: Sendable> {
    private var items: [Item] = []
    private var waiter: CheckedContinuation<Item?, Never>?
    private var closed = false

    func put(_ item: Item) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    func close() {
        closed = true
        release()
    }

    private func release() {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func next(within limit: Duration? = .seconds(3)) async -> Item? {
        if !items.isEmpty { return items.removeFirst() }
        if closed { return nil }
        let timeout = limit.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { self.release() }
            }
        }
        defer { timeout?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }

    var isEmpty: Bool { items.isEmpty }
}

/// The server side of the handshake, for the fake VM only.
struct NoiseXXResponder {
    private var state = SymmetricState()
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let staticKey = Curve25519.KeyAgreement.PrivateKey()

    mutating func readMessage1WriteMessage2(_ message: [UInt8]) throws -> [UInt8] {
        let remote = Array(message[..<32])
        state.mixHash(remote)
        _ = try state.decryptAndHash(Array(message[32...]))
        let publicKey = Array(ephemeral.publicKey.rawRepresentation)
        state.mixHash(publicKey)
        state.mixKey(try x25519(ephemeral, remote))
        let encryptedStatic = try state.encryptAndHash(Array(staticKey.publicKey.rawRepresentation))
        state.mixKey(try x25519(staticKey, remote))
        return publicKey + encryptedStatic + (try state.encryptAndHash([]))
    }

    mutating func readMessage3(_ message: [UInt8]) throws -> (send: CipherState, receive: CipherState) {
        let remoteStatic = try state.decryptAndHash(Array(message[..<48]))
        state.mixKey(try x25519(ephemeral, remoteStatic))
        _ = try state.decryptAndHash(Array(message[48...]))
        let (first, second) = state.split()
        return (second, first)
    }
}

/// A Muse VM that completes the handshake, accepts registration and the
/// reply subscription, and hands every other request to the test.
actor FakeVM {
    let toClient = Mailbox<Data>()
    /// Requests the bridge forwarded, in order.
    let forwarded = Mailbox<ServiceFrame>()
    let url: URL
    let headers: [String: String]
    private var responder = NoiseXXResponder()
    private var ciphers: (send: CipherState, receive: CipherState)?
    private var decoder = NoiseFrameDecoder()
    private var sawFirstMessage = false
    private var controlBuffer: [UInt8] = []
    private(set) var controlStream: Int64 = 0
    private(set) var subscriptionStream: Int64 = 0
    private(set) var registration: [String: Any]?
    private(set) var subscriptionHeaders: [NoiseHeader] = []
    private(set) var results: [[String: Any]] = []
    var subscriptionStatus: Int32 = 200

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func setSubscriptionStatus(_ status: Int32) { subscriptionStatus = status }
    var registrationJSON: Data? { registration.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } }
    var resultsJSON: Data? { try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]) }

    func clientSent(_ data: Data) async throws {
        guard var ciphers else {
            if !sawFirstMessage {
                sawFirstMessage = true
                await toClient.put(Data(try responder.readMessage1WriteMessage2([UInt8](data))))
            } else {
                self.ciphers = try responder.readMessage3([UInt8](data))
            }
            return
        }
        let plain = try ciphers.receive.decrypt(ad: [], [UInt8](data))
        self.ciphers = ciphers
        guard let whole = try decoder.decode(plain) else { return }
        let frame = try ServiceFrame(decoding: try decodeServiceRequest(whole))
        switch frame.value {
        case let .request(_, path, headers, _, _) where path == "/link-control":
            controlStream = frame.streamID
            _ = headers
            await push(ServiceFrame(streamID: frame.streamID, value: .response(status: 200, headers: [], body: [], end: false)))
        case let .request(_, path, headers, _, _) where path == "/chat/subscribe":
            subscriptionStream = frame.streamID
            subscriptionHeaders = headers
            await push(ServiceFrame(streamID: frame.streamID, value: .response(
                status: subscriptionStatus, headers: [], body: [], end: false)))
        case let .bodyChunk(data, _) where frame.streamID == controlStream:
            controlBuffer += data
            while controlBuffer.count >= 4 {
                let length = (0..<4).reduce(0) { $0 | Int(controlBuffer[$1]) << (8 * $1) }
                guard controlBuffer.count >= 4 + length else { break }
                let message = try JSONSerialization.jsonObject(with: Data(controlBuffer[4..<4 + length])) as? [String: Any] ?? [:]
                controlBuffer.removeFirst(4 + length)
                if message["method"] as? String == "link.register" {
                    registration = message["params"] as? [String: Any]
                    await control(["id": message["id"] ?? "", "result": ["ok": true]])
                } else {
                    results.append(message)
                }
            }
        default:
            await forwarded.put(frame)
        }
    }

    func push(_ frame: ServiceFrame) async {
        guard var ciphers else { return }
        for part in (try? encodeNoiseFrames(encodeServiceResponse(frame.encoded()), chunkID: .random(in: 1...9999))) ?? [] {
            if let sealed = try? ciphers.send.encrypt(ad: [], part) { await toClient.put(Data(sealed)) }
        }
        self.ciphers = ciphers
    }

    /// A length-prefixed JSON message on the control stream.
    func control(_ message: [String: Any]) async {
        let body = [UInt8]((try? JSONSerialization.data(withJSONObject: message)) ?? Data())
        let length = (0..<4).map { UInt8(truncatingIfNeeded: body.count >> (8 * $0)) }
        await push(ServiceFrame(streamID: controlStream, value: .bodyChunk(length + body, end: false)))
    }

    /// One NDJSON event on the reply subscription.
    func event(_ name: String, _ payload: [String: Any]) async {
        let line = (try? JSONSerialization.data(withJSONObject: ["type": "event", "event": name, "payload": payload])) ?? Data()
        await push(ServiceFrame(streamID: subscriptionStream, value: .bodyChunk([UInt8](line) + [0x0A], end: false)))
    }

    func drop() async { await toClient.close() }
}

final class FakeSocket: MuseSocket {
    let vm: FakeVM
    init(vm: FakeVM) { self.vm = vm }

    func send(_ data: Data) async throws { try await vm.clientSent(data) }

    func receive() async throws -> Data {
        guard let data = await vm.toClient.next(within: nil) else { throw MuseNetworkError.io }
        return data
    }

    func close() { Task { await vm.toClient.close() } }
}

struct HTTPCall: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

/// Scripted account API plus one fresh `FakeVM` per WebSocket.
actor FakeNetwork: MuseNetwork {
    private(set) var calls: [HTTPCall] = []
    private(set) var vms: [FakeVM] = []
    private var responses: [@Sendable (HTTPCall) -> (Int, String)?] = []
    var subscriptionStatus: Int32 = 200
    var openError: MuseNetworkError?

    func setOpenError(_ error: MuseNetworkError?) { openError = error }
    func setSubscriptionStatus(_ status: Int32) { subscriptionStatus = status }

    /// Earlier handlers win; return nil to pass a call on.
    func respond(_ handler: @escaping @Sendable (HTTPCall) -> (Int, String)?) { responses.insert(handler, at: 0) }

    func http(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        let call = HTTPCall(method: method, url: url, headers: headers, body: body)
        calls.append(call)
        for handler in responses {
            if let (status, text) = handler(call) { return (status, Data(text.utf8)) }
        }
        return (200, Data(#"{"vm_list":[{"vm_id":"other","vm_auth_token":"t0"},{"vm_id":"vm/1","vm_auth_token":"vmtoken"}]}"#.utf8))
    }

    func openWebSocket(_ url: URL, headers: [String: String]) async throws -> any MuseSocket {
        if let openError { throw openError }
        let vm = FakeVM(url: url, headers: headers)
        await vm.setSubscriptionStatus(subscriptionStatus)
        vms.append(vm)
        return FakeSocket(vm: vm)
    }
}
