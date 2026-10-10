import Foundation
import Testing
@testable import PassportBridge

private typealias DeviceMessage = (type: UInt8, id: UInt16, body: Data)

/// A bridge wired to a fake network and a recording device.
private struct Rig {
    let network = FakeNetwork()
    let device = Mailbox<BridgeMessage>()
    let states = Mailbox<BridgeState>()
    let bridge: Bridge

    init(firstRetry: Duration = .seconds(60), credentials: Duration = .seconds(5),
         speech: (@Sendable (SpeechCommand) async -> Void)? = nil) {
        var timing = BridgeTiming()
        timing.firstRetry = firstRetry
        timing.credentials = credentials
        timing.sdkSettings = .milliseconds(200)
        timing.tokenCommit = .milliseconds(300)
        let device = device, states = states
        bridge = Bridge(network: network, userAgent: "MusePassport/test", timing: timing, send: { type, id, body in
            await device.put(BridgeMessage(type: type, id: id, sequence: 0, body: body))
            return true
        }, onState: { state in Task { await states.put(state) } }, speech: speech)
    }

    static var credentials: [String: Any] {
        ["access_token": "access", "refresh_token": "hatch_refresh:secret", "api_url_v2": "https://api.example/",
         "noise_host": "noise.example", "node_id": "homelink-2f571c", "device_id": "hatch-link:1", "version": "1.0.1",
         "sdk_token": "mgst_x", "vm_id": "vm/1", "sdk_settings": true, "sdk_token_configured": true]
    }

    func send(_ type: UInt8, _ id: UInt16 = 0, _ body: Data = Data()) async {
        await bridge.receive(BridgeMessage(type: type, id: id, sequence: 0, body: body))
    }

    func send(_ type: UInt8, _ id: UInt16 = 0, json: [String: Any]) async {
        await send(type, id, try! JSONSerialization.data(withJSONObject: json))
    }

    /// Sends the credentials and waits until Muse is connected.
    func connect(_ overrides: [String: Any] = [:]) async throws -> FakeVM {
        await send(BridgeMessageType.credentials, json: Self.credentials.merging(overrides) { $1 })
        let ready = try #require(await device.next())
        #expect(ready.type == BridgeMessageType.ready)
        try await waitForState { $0.museConnected }
        return try #require(await network.vms.last)
    }

    @discardableResult
    func waitForState(_ matches: (BridgeState) -> Bool) async throws -> BridgeState {
        while let state = await states.next() {
            if matches(state) { return state }
        }
        throw BridgeFailure.transient("state never reached")
    }

    func open(_ id: UInt16, _ verb: String, _ path: String, end: Bool, audio: Bool = false,
              headers: [[String]] = []) async {
        var info: [String: Any] = ["verb": verb, "path": path, "end": end, "headers": headers]
        if audio { info["audio"] = "ima-adpcm-16000-v1" }
        await send(BridgeMessageType.open, id, json: info)
    }

    /// Gathers the pieces of one response into its status and body.
    func response(_ id: UInt16) async throws -> (status: Int, body: Data) {
        var status = 0, body = Data(), first = true
        while true {
            let message = try #require(await device.next())
            #expect(message.type == BridgeMessageType.response && message.id == id)
            let bytes = [UInt8](message.body)
            if first { status = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)) }
            first = false
            body += bytes[3...]
            if bytes[2] != 0 { return (status, body) }
        }
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// One 2-sample ADPCM block, as the firmware frames it.
private func audioBlock(_ sequence: UInt8, end: Bool) -> Data {
    Data([end ? 1 : 0, 0, 0, 0, 2, 0, sequence, 0, 0, 0, 0x00])
}

@Suite struct BridgeTests {
    @Test func speechNegotiationAndStatusDispatchAreOptional() async throws {
        let commands = Mailbox<SpeechCommand>()
        let rig = Rig(speech: { await commands.put($0) })
        await rig.send(BridgeMessageType.credentials, json: Rig.credentials.merging(["reply_speech": "opus-16000-60-v1"]) { $1 })
        let ready = try #require(await rig.device.next())
        #expect(try object(ready.body)["reply_speech"] as? String == "opus-16000-60-v1")
        let state = try await rig.waitForState { $0.museConnected }
        #expect(state.speechSupported)
        await rig.send(13, json: ["session": 0x12345678, "limit": 8, "note": "missing", "message": "r"])
        guard case let .request(session, text, limit) = try #require(await commands.next()) else { Issue.record("missing request"); return }
        #expect(session == 0x12345678 && text.isEmpty && limit == 8)
        await rig.send(15, 0, speechPacket(session: session, frame: 12, kind: 1))
        guard case let .status(status) = try #require(await commands.next()) else { Issue.record("missing status"); return }
        #expect(status.session == session && status.limit == 12 && status.state == 1)
        await rig.bridge.stop()
        let legacy = Rig(speech: { await commands.put($0) })
        _ = try await legacy.connect()
        await legacy.send(13, json: ["session": 1, "limit": 8, "note": "n", "message": "r"])
        #expect(await commands.next(within: .milliseconds(50)) == nil)
        await legacy.bridge.stop()
    }
    @Test func sourceFollowingRequiresBothCapabilityAndRequest() async throws {
        let commands = Mailbox<SpeechCommand>()
        let rig = Rig(speech: { await commands.put($0) })
        await rig.send(BridgeMessageType.credentials, json: Rig.credentials.merging([
            "reply_speech": "opus-16000-60-v1", "speech_follow": "source-v1"
        ]) { $1 })
        let ready = try #require(await rig.device.next())
        #expect(try object(ready.body)["speech_follow"] as? String == "source-v1")
        let state = try await rig.waitForState { $0.museConnected }
        #expect(state.speechFollowSupported)
        let request: [String: Any] = ["session": 1, "limit": 8, "note": "missing", "message": "r"]
        await rig.send(BridgeMessageType.speechRequest, json: request)
        guard case .request = try #require(await commands.next()) else { Issue.record("legacy request changed"); return }
        await rig.send(BridgeMessageType.speechRequest, json: request.merging(["speech_follow": "source-v1"]) { $1 })
        guard case let .followRequest(session, text, limit) = try #require(await commands.next()) else { Issue.record("missing source request"); return }
        #expect(session == 1 && text.isEmpty && limit == 8)
        await rig.bridge.stop()
    }

    @Test func credentialsMakeTheDeviceReadyAndConnectMuse() async throws {
        let rig = Rig()
        let vm = try await rig.connect()

        #expect(vm.url.absoluteString == "wss://noise.example/v1/noise?vm_id=vm%2F1")
        #expect(vm.headers == ["Authorization": "Bearer vmtoken"])
        let registration = try object(try #require(await vm.registrationJSON))
        #expect(registration["platform"] as? String == "esp32")
        #expect(registration["model_id"] as? String == "esp-link")
        #expect(registration["device_family"] as? String == "link")
        #expect(registration["node_id"] as? String == "homelink-2f571c")
        #expect(registration["version"] as? String == "1.0.1")
        #expect(await vm.subscriptionHeaders.contains(NoiseHeader("x-app-id", "hatch-web")))

        let call = try #require(await rig.network.calls.first)
        #expect(call.method == "GET" && call.url.absoluteString == "https://api.example/fetch_vms")
        #expect(call.headers == ["Authorization": "Bearer access", "X-API-Version": "1.0.0", "User-Agent": "MusePassport/test"])
    }

    @Test func aDeviceWithoutAnAccountBindingIsNotMadeReady() async throws {
        let rig = Rig()
        await rig.send(BridgeMessageType.credentials, json: ["access_token": "", "sdk_settings": true])
        let state = try await rig.waitForState { $0.status.contains("账号绑定") }
        #expect(state.sdkSettingsSupported && !state.sdkTokenConfigured)
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)
        #expect(await rig.network.calls.isEmpty)
    }

    @Test func aTurnIsForwardedAndReadBackFromTheCache() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await rig.open(7, "POST", "/chat/stream", end: false, audio: true,
                       headers: [["Content-Type", "application/json"], ["x-request-id", "r1"], ["Cookie", "secret"]])
        await rig.send(BridgeMessageType.data, 7, audioBlock(0, end: false))
        await rig.send(BridgeMessageType.data, 7, audioBlock(1, end: true))

        let request = try #require(await vm.forwarded.next())
        guard case let .request(verb, path, headers, _, end) = request.value else { Issue.record("not a request"); return }
        #expect(verb == "POST" && path == "/chat/stream" && !end)
        #expect(headers == [NoiseHeader("Content-Type", "application/json"), NoiseHeader("x-request-id", "r1")])
        var body: [UInt8] = [], ended = false
        while !ended {
            guard case let .bodyChunk(data, end) = try #require(await vm.forwarded.next()).value else { Issue.record("not a chunk"); return }
            body += data
            ended = end
        }
        let upload = try object(Data(body))
        let item = try #require((upload["items"] as? [[String: Any]])?.first)
        #expect(Data(base64Encoded: try #require(item["data_base64"] as? String))?.count == 44 + 8)

        await vm.push(ServiceFrame(streamID: request.streamID, value: .response(
            status: 200, headers: [], body: Array(#"{"ok":true,"result":{"message_id":"note-1"}}"#.utf8), end: true)))
        let ack = try await rig.response(7)
        #expect(ack.status == 200)
        #expect(try object(ack.body)["ok"] as? Bool == true)

        await vm.event("message.user", ["message_id": "note-1", "display_text": "你好"])
        await vm.event("message.assistant", ["message_id": "reply-1", "reply_to_message_id": "note-1", "display_text": "你好，我是 Muse。"])
        // Events and requests travel separately; poll as the firmware does.
        var row: [String: Any]?
        for attempt in 0..<50 where row == nil {
            await rig.open(UInt16(100 + attempt), "GET", "/chat/history?limit=1&after_seq=1", end: true)
            let page = try await rig.response(UInt16(100 + attempt))
            #expect(page.status == 200)
            row = ((try object(page.body)["result"] as? [String: Any])?["chat_events"] as? [[String: Any]])?.first
            if row == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(row?["display_text"] as? String == "你好，我是 Muse。")
        #expect(row?["reply_to_message_id"] as? String == "note-1")

        await rig.open(9, "GET", "/passport/reader?note=note-1&page=0", end: true)
        let reader = try object(try await rig.response(9).body)
        #expect(reader["role"] as? String == "user" && reader["text"] as? String == "你好")
    }

    @Test func losingMuseKeepsTheDeviceReadyAndReconnectsOnDemand() async throws {
        let rig = Rig()
        let first = try await rig.connect()
        await rig.open(1, "POST", "/chat/stream", end: false, audio: true)
        let request = try #require(await first.forwarded.next())
        _ = await first.forwarded.next()
        await first.push(ServiceFrame(streamID: request.streamID, value: .response(
            status: 200, headers: [], body: Array(#"{"result":{"message_id":"n"}}"#.utf8), end: true)))
        #expect(try await rig.response(1).status == 200)
        await first.event("message.assistant", ["message_id": "r", "reply_to_message_id": "n", "display_text": "回复"])
        var seen = false
        for attempt in 0..<50 where !seen {
            await rig.open(UInt16(100 + attempt), "GET", "/chat/history?after_seq=1", end: true)
            seen = String(decoding: try await rig.response(UInt16(100 + attempt)).body, as: UTF8.self).contains("回复")
            if !seen { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(seen)

        await first.drop()
        // Nothing tells the device it is no longer ready.
        try await rig.waitForState { !$0.museConnected && $0.status.contains("正在重试") }
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)

        // The current turn stays readable without Muse; new history does not.
        await rig.open(3, "GET", "/chat/history?after_seq=0", end: true)
        #expect(try await rig.response(3).status == -1)
        await rig.open(4, "GET", "/passport/reader?note=n", end: true)
        #expect(try object(try await rig.response(4).body)["text"] as? String == "回复")

        // The next turn reconnects at once, while audio keeps arriving.
        await rig.open(5, "POST", "/chat/stream", end: false, audio: true)
        await rig.send(BridgeMessageType.data, 5, audioBlock(0, end: true))
        try await rig.waitForState { $0.museConnected }
        #expect(await rig.network.vms.count == 2)
        let second = try #require(await rig.network.vms.last)
        guard case .request = try #require(await second.forwarded.next()).value else { Issue.record("not a request"); return }
        var ended = false
        while !ended {
            guard case let .bodyChunk(_, end) = try #require(await second.forwarded.next()).value else { Issue.record("not a chunk"); return }
            ended = end
        }
    }

    /// A connection that died while the app was suspended, or with a change
    /// of network, is often noticed only once a turn has started on it.
    @Test func aTurnInterruptedByLosingMuseIsSentAgainOnceReconnected() async throws {
        let rig = Rig()
        let first = try await rig.connect()
        await rig.open(6, "POST", "/chat/stream", end: false, audio: true)
        await rig.send(BridgeMessageType.data, 6, audioBlock(0, end: false))
        _ = await first.forwarded.next()
        await first.drop()
        try await rig.waitForState { !$0.museConnected }
        await rig.send(BridgeMessageType.data, 6, audioBlock(1, end: true))

        try await rig.waitForState { $0.museConnected }
        #expect(await rig.network.vms.count == 2)
        let second = try #require(await rig.network.vms.last)
        let request = try #require(await second.forwarded.next())
        guard case let .request(verb, path, _, _, _) = request.value else { Issue.record("not a request"); return }
        #expect(verb == "POST" && path == "/chat/stream")
        var body: [UInt8] = [], ended = false
        while !ended {
            guard case let .bodyChunk(data, end) = try #require(await second.forwarded.next()).value else { Issue.record("not a chunk"); return }
            body += data
            ended = end
        }
        // Both blocks arrive, including the one sent before the connection was lost.
        let item = try #require((try object(Data(body))["items"] as? [[String: Any]])?.first)
        #expect(Data(base64Encoded: try #require(item["data_base64"] as? String))?.count == 44 + 8)

        await second.push(ServiceFrame(streamID: request.streamID, value: .response(
            status: 200, headers: [], body: Array(#"{"ok":true}"#.utf8), end: true)))
        // The device hears of one outcome only: the answer.
        #expect(try await rig.response(6).status == 200)
    }

    /// Muse may already be acting on a request sent in full, so it is not sent twice.
    @Test func aRequestAwaitingItsAnswerFailsWhenMuseDrops() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await rig.open(2, "POST", "/chat/stream", end: false)
        await rig.send(BridgeMessageType.data, 2, Data([1]))
        _ = await vm.forwarded.next()
        _ = await vm.forwarded.next()
        await vm.drop()
        #expect(try await rig.response(2).status == -1)
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)
    }

    /// The system relaunches a terminated app for the turn itself, so the
    /// request arrives before the device has answered the greeting.
    @Test func aTurnThatArrivesBeforeTheCredentialsWaitsForThem() async throws {
        let rig = Rig()
        await rig.open(1, "POST", "/chat/stream", end: false, audio: true)
        await rig.send(BridgeMessageType.data, 1, audioBlock(0, end: true))
        try await Task.sleep(for: .milliseconds(50))
        await rig.send(BridgeMessageType.credentials, json: Rig.credentials)

        #expect(await rig.device.next()?.type == BridgeMessageType.ready)
        try await rig.waitForState { $0.museConnected }
        let vm = try #require(await rig.network.vms.last)
        guard case let .request(_, path, _, _, _) = try #require(await vm.forwarded.next()).value else { Issue.record("not a request"); return }
        #expect(path == "/chat/stream")
        var ended = false
        while !ended {
            guard case let .bodyChunk(_, end) = try #require(await vm.forwarded.next()).value else { Issue.record("not a chunk"); return }
            ended = end
        }
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)
    }

    /// Several callers can be waiting for the credentials at once; giving up
    /// must release all of them, or Muse is never connected afterwards.
    @Test func credentialsThatArriveLateStillConnectMuse() async throws {
        let rig = Rig(firstRetry: .milliseconds(10), credentials: .milliseconds(60))
        await rig.open(1, "POST", "/chat/stream", end: true)
        #expect(try await rig.response(1).status == -1)
        try await Task.sleep(for: .milliseconds(30))
        await rig.open(2, "POST", "/chat/stream", end: true)
        #expect(try await rig.response(2).status == -1)
        try await Task.sleep(for: .milliseconds(100))

        await rig.send(BridgeMessageType.credentials, json: Rig.credentials)
        #expect(await rig.device.next()?.type == BridgeMessageType.ready)
        try await rig.waitForState { $0.museConnected }
    }

    /// The cache outlives a Muse connection, but a line that the lost
    /// connection cut short must not be joined to the first line of the next.
    @Test func aReplyCutOffMidLineDoesNotSpoilTheNextConnection() async throws {
        let rig = Rig(firstRetry: .milliseconds(10))
        let first = try await rig.connect()
        await rig.open(1, "POST", "/chat/stream", end: true)
        let request = try #require(await first.forwarded.next())
        await first.push(ServiceFrame(streamID: request.streamID, value: .response(
            status: 200, headers: [], body: Array(#"{"result":{"message_id":"n"}}"#.utf8), end: true)))
        #expect(try await rig.response(1).status == 200)
        await first.push(ServiceFrame(streamID: await first.subscriptionStream, value: .bodyChunk(
            Array(#"{"type":"event","eve"#.utf8), end: false)))
        await first.drop()
        try await rig.waitForState { !$0.museConnected }
        try await rig.waitForState { $0.museConnected }

        let second = try #require(await rig.network.vms.last)
        await second.event("message.assistant", ["message_id": "r", "reply_to_message_id": "n", "display_text": "回复"])
        var seen = false
        for attempt in 0..<50 where !seen {
            await rig.open(UInt16(100 + attempt), "GET", "/chat/history?after_seq=1", end: true)
            seen = String(decoding: try await rig.response(UInt16(100 + attempt)).body, as: UTF8.self).contains("回复")
            if !seen { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(seen)
        #expect(await rig.network.vms.count == 2)
    }

    @Test func aFailedReconnectFailsOnlyThatTurn() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await vm.drop()
        try await rig.waitForState { !$0.museConnected }
        await rig.network.setOpenError(.dns)
        await rig.open(1, "POST", "/chat/stream", end: false, audio: true)
        #expect(try await rig.response(1).status == -1)
        let state = try await rig.waitForState { $0.status.contains("域名解析失败") }
        #expect(state.status.hasPrefix("Muse WebSocket 连接失败"))
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)

        await rig.network.setOpenError(nil)
        await rig.open(2, "POST", "/chat/stream", end: true)
        try await rig.waitForState { $0.museConnected }
        #expect(await rig.network.vms.count == 2)
    }

    @Test func expiredCredentialsAreRefreshedAndCommittedOnTheDevice() async throws {
        let rig = Rig()
        await rig.network.respond { call in
            if call.url.path == "/device_token/refresh" {
                return (200, #"{"payload":{"access_token":"access2","refresh_token":"hatch_refresh:secret2"}}"#)
            }
            return call.headers["Authorization"] == "Bearer access" ? (401, "{}") : nil
        }
        await rig.send(BridgeMessageType.credentials, json: Rig.credentials)
        #expect(await rig.device.next()?.type == BridgeMessageType.ready)
        let tokens = try #require(await rig.device.next())
        #expect(tokens.type == BridgeMessageType.tokens)
        #expect(try object(tokens.body)["access_token"] as? String == "access2")
        await rig.send(BridgeMessageType.tokens, json: ["ok": true])
        try await rig.waitForState { $0.museConnected }

        let calls = await rig.network.calls
        #expect(calls.map(\.url.path) == ["/fetch_vms", "/device_token/refresh", "/fetch_vms"])
        #expect(calls[1].headers["Authorization"] == "Bearer hatch_refresh:secret")
        let refresh = try object(try #require(calls[1].body))
        #expect(refresh["device_id"] as? String == "hatch-link:1" && refresh["sdk_token"] as? String == "mgst_x")
        #expect(calls[2].headers["Authorization"] == "Bearer access2")
    }

    @Test func aLostAccountBindingWithdrawsReadinessForGood() async throws {
        let rig = Rig()
        await rig.network.respond { _ in (401, "{}") }
        await rig.send(BridgeMessageType.credentials, json: Rig.credentials)
        #expect(await rig.device.next()?.type == BridgeMessageType.ready)
        #expect(await rig.device.next()?.type == BridgeMessageType.error)
        try await rig.waitForState { $0.status.contains("账号绑定") }

        let before = await rig.network.calls.count
        await rig.open(1, "POST", "/chat/stream", end: true)
        #expect(try await rig.response(1).status == -1)
        #expect(await rig.network.calls.count == before)
    }

    @Test func unpairingByMuseIsPermanent() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await vm.control(["event": "link.unpaired"])
        #expect(await rig.device.next()?.type == BridgeMessageType.error)
        try await rig.waitForState { $0.status.contains("移除") }
    }

    @Test func remoteCommandsAreDeclined() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await vm.control(["method": "link.invoke", "id": "i1", "command": "shell"])
        var results: [[String: Any]] = []
        for _ in 0..<100 where results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            results = (try JSONSerialization.jsonObject(with: try #require(await vm.resultsJSON)) as? [[String: Any]]) ?? []
        }
        #expect(results.first?["method"] as? String == "link.result" && results.first?["id"] as? String == "i1")
        #expect((results.first?["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }

    @Test func cancellingResetsTheStream() async throws {
        let rig = Rig()
        let vm = try await rig.connect()
        await rig.open(3, "POST", "/chat/stream", end: false)
        let request = try #require(await vm.forwarded.next())
        await rig.send(BridgeMessageType.cancel, 3)
        let reset = try #require(await vm.forwarded.next())
        #expect(reset == ServiceFrame(streamID: request.streamID, value: .reset(code: 1, reason: "")))
        // Data for a cancelled request is refused.
        await rig.send(BridgeMessageType.data, 3, Data([1]))
        #expect(try await rig.response(3).status == -1)
    }

    @Test func requestsOutsideTheAllowedSetAreRefused() async throws {
        let rig = Rig()
        _ = try await rig.connect()
        await rig.open(1, "GET", "/files/secret", end: true)
        #expect(try await rig.response(1).status == -1)
        await rig.open(2, "POST", "/passport/reader?note=x", end: true)
        #expect(try await rig.response(2).status == -1)
        await rig.send(BridgeMessageType.open, 3, json: ["verb": "POST", "path": "/chat/stream", "end": false, "audio": "opus"])
        #expect(try await rig.response(3).status == -1)
        for id in UInt16(10)..<14 { await rig.open(id, "POST", "/chat/stream", end: false) }
        await rig.open(14, "POST", "/chat/stream", end: false)
        #expect(try await rig.response(14).status == -1)
    }

    @Test func sdkTokenIsValidatedSavedAndCleared() async throws {
        let rig = Rig()
        _ = try await rig.connect()
        await rig.bridge.updateSDKToken("not-a-token")
        try await rig.waitForState { $0.sdkSettingsStatus.contains("mgst_") }
        #expect(await rig.device.next(within: .milliseconds(100)) == nil)

        await rig.bridge.updateSDKToken("mgst_abc-DEF_123")
        let request = try #require(await rig.device.next())
        #expect(request.type == BridgeMessageType.sdkSettings)
        let body = try object(request.body)
        #expect(body["action"] as? String == "set" && body["token"] as? String == "mgst_abc-DEF_123")
        await rig.send(BridgeMessageType.sdkSettings, request.id, json: ["ok": true, "configured": true, "restart": true])
        let saved = try await rig.waitForState { !$0.sdkSettingsPending && $0.sdkSettingsStatus.contains("已保存") }
        #expect(saved.sdkTokenConfigured)

        await rig.bridge.updateSDKToken(nil)
        let clear = try #require(await rig.device.next())
        #expect(try object(clear.body)["action"] as? String == "clear" && clear.id != request.id)
        // No answer from the device: the request times out without claiming success.
        try await rig.waitForState { !$0.sdkSettingsPending && $0.sdkSettingsStatus.contains("未收到保存确认") }
    }
}
