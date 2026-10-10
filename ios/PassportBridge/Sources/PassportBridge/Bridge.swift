import Foundation

/// What the app shows about one Bluetooth connection to a Passport.
public struct BridgeState: Equatable, Sendable {
    public var status = "蓝牙已连接，正在获取设备凭据…"
    /// The Muse connection is up right now. The device stays ready without it.
    public var museConnected = false
    public var sdkSettingsSupported = false
    public var sdkTokenConfigured = false
    public var sdkSettingsPending = false
    public var sdkSettingsStatus = "连接 Passport 后可设置 SDK token"
    public var speechSupported = false
    public var speechFollowSupported = false

    public init() {}
}

/// Waits and limits, shortened by tests.
public struct BridgeTiming: Sendable {
    /// One attempt to reach Muse. A request from the device waits this long
    /// at most; the device itself gives a turn 60 seconds.
    public var connect: Duration = .seconds(25)
    public var credentials: Duration = .seconds(5)
    public var tokenCommit: Duration = .seconds(15)
    public var sdkSettings: Duration = .seconds(10)
    public var firstRetry: Duration = .seconds(2)
    public var lastRetry: Duration = .seconds(30)

    public init() {}
}

/// Relays one Passport's turns to Muse for the lifetime of a Bluetooth connection.
///
/// Unlike the Android bridge, the Muse connection is made on demand: iOS
/// suspends the app whenever the device is quiet, so the device is told it is
/// ready as soon as its credentials are known and stays ready when the Muse
/// connection drops. Only a lost account binding withdraws readiness.
public actor Bridge {
    public static let apiVersion = "1.0.0"
    static let responseLimit = 1024 * 1024
    static let chunk = 1800

    private final class Session {
        let socket: any MuseSocket
        var transport: NoiseTransport
        let frames: AsyncStream<Data>.Continuation
        var controlStream: Int64 = 0
        var registerID = ""
        var controlBuffer: [UInt8] = []
        var subscriptionStream: Int64?
        var ready = false
        var forwards: [Int64: (request: UInt16, received: Int, ack: Data)] = [:]
        var streams: [UInt16: Int64] = [:]
        var audio: [UInt16: AudioUpload] = [:]
        var noteRequest: UInt16?
        var tasks: [Task<Void, Never>] = []

        init(socket: any MuseSocket, transport: NoiseTransport, frames: AsyncStream<Data>.Continuation) {
            self.socket = socket
            self.transport = transport
            self.frames = frames
        }
    }

    private struct Credentials {
        var accessToken, refreshToken, apiURL, noiseHost, nodeID, deviceID, version, sdkToken, vmID: String
    }

    private let network: any MuseNetwork
    private let userAgent: String
    private let timing: BridgeTiming
    private let onState: @Sendable (BridgeState) -> Void
    private let speech: (@Sendable (SpeechCommand) async -> Void)?
    private let toDevice: AsyncStream<(UInt8, UInt16, Data)>.Continuation
    private let commands: AsyncStream<BridgeMessage>.Continuation
    private var workers: [Task<Void, Never>] = []

    private var state = BridgeState()
    private var credentials: Credentials?
    /// Lives as long as the Bluetooth connection, across Muse reconnects.
    private var cache = ReplyCache()
    /// The messages of every request whose body is still arriving. Muse cannot
    /// have answered such a request, so when the connection is lost it is sent
    /// again from the start on the next one instead of failing the turn.
    private var unfinished: [UInt16: [BridgeMessage]] = [:]
    private var session: Session?
    private var generation = 0
    private var connecting: Task<Void, Error>?
    private var keeper: Task<Void, Never>?
    private var stage = "Muse 账号信息获取"
    private var permanentFailure: String?
    private var stopped = false
    private var tokenWaiter: CheckedContinuation<Bool, Never>?
    /// A turn and the reconnect loop can both be waiting.
    private var credentialsWaiters: [CheckedContinuation<Void, Never>] = []
    private var settingsRequest: UInt16 = 0

    /// - Parameter send: writes one message to the device; false once Bluetooth is gone.
    public init(network: any MuseNetwork, userAgent: String, timing: BridgeTiming = BridgeTiming(),
                send: @escaping @Sendable (UInt8, UInt16, Data) async -> Bool,
                onState: @escaping @Sendable (BridgeState) -> Void,
                speech: (@Sendable (SpeechCommand) async -> Void)? = nil) {
        self.network = network
        self.userAgent = userAgent
        self.timing = timing
        self.onState = onState
        self.speech = speech
        let (outgoing, toDevice) = AsyncStream<(UInt8, UInt16, Data)>.makeStream()
        let (incoming, commands) = AsyncStream<BridgeMessage>.makeStream(bufferingPolicy: .bufferingOldest(512))
        self.toDevice = toDevice
        self.commands = commands
        // One writer keeps device messages in order without blocking the bridge.
        let writer = Task {
            for await (type, id, body) in outgoing {
                if !(await send(type, id, body)) { break }
            }
        }
        workers = [writer]
        Task { await self.start(incoming) }
    }

    private func start(_ incoming: AsyncStream<BridgeMessage>) {
        // Requests wait here, in order, while Muse reconnects.
        workers.append(Task { for await message in incoming { await self.command(message) } })
    }

    public func stop() {
        stopped = true
        keeper?.cancel()
        connecting?.cancel()
        workers.forEach { $0.cancel() }
        commands.finish()
        toDevice.finish()
        resolveTokenCommit(false)
        resolveCredentialsWait()
        if let session { close(session) }
        session = nil
        credentials = nil
    }

    // MARK: Messages from the device

    /// Call for every message, in arrival order.
    public func receive(_ message: BridgeMessage) async {
        guard !stopped else { return }
        switch message.type {
        case BridgeMessageType.credentials: receivedCredentials(message.body)
        case BridgeMessageType.tokens:
            resolveTokenCommit((Self.object(message.body)?["ok"] as? Bool) == true)
        case BridgeMessageType.sdkSettings: receivedSDKSettings(message)
        case BridgeMessageType.speechRequest:
            if state.speechSupported, let request = Self.object(message.body),
               let session = request["session"] as? UInt32,
               let limit = request["limit"] as? UInt32,
               let note = request["note"] as? String, let id = request["message"] as? String {
                let text = cache.speechText(note: note, message: id) ?? ""
                if state.speechFollowSupported, request["speech_follow"] as? String == "source-v1" {
                    await speech?(.followRequest(session: session, text: text, limit: limit))
                } else { await speech?(.request(session: session, text: text, limit: limit)) }
            }
        case BridgeMessageType.speechStatus:
            if let status = try? SpeechStatus(message.body) { await speech?(.status(status)) }
        case BridgeMessageType.open, BridgeMessageType.data, BridgeMessageType.cancel:
            if case .dropped = commands.yield(message) {
                update { $0.status = "蓝牙接收队列已满，请重连" }
                respond(message.id, status: -1)
            }
        default: break
        }
    }

    private func receivedCredentials(_ body: Data) {
        guard credentials == nil, let info = Self.object(body) else { return }
        func text(_ key: String) -> String { info[key] as? String ?? "" }
        credentials = Credentials(
            accessToken: text("access_token"), refreshToken: text("refresh_token"), apiURL: text("api_url_v2"),
            noiseHost: text("noise_host"), nodeID: text("node_id"), deviceID: text("device_id"),
            version: text("version"), sdkToken: text("sdk_token"), vmID: text("vm_id"))
        resolveCredentialsWait()
        let supported = info["sdk_settings"] as? Bool == true, configured = info["sdk_token_configured"] as? Bool == true
        update {
            $0.speechSupported = speech != nil && text("reply_speech") == "opus-16000-60-v1"
            $0.speechFollowSupported = $0.speechSupported && text("speech_follow") == "source-v1"
            $0.sdkSettingsSupported = supported
            $0.sdkTokenConfigured = configured
            if !$0.sdkSettingsPending {
                $0.sdkSettingsStatus = !supported ? "请升级 Passport 固件以设置 SDK token"
                    : configured ? "SDK token 已设置" : "尚未设置 SDK token"
            }
        }
        guard !text("access_token").isEmpty else {
            update { $0.status = "Passport 尚未在 Muse App 中完成账号绑定" }
            return
        }
        // Ready means this app is reachable, not that Muse is connected yet.
        var capability = state.speechSupported ? ["reply_speech": "opus-16000-60-v1"] : [:]
        if state.speechFollowSupported { capability["speech_follow"] = "source-v1" }
        emit(BridgeMessageType.ready, 0, Self.json(capability))
        keepConnected(afterDrop: false)
    }

    private func command(_ message: BridgeMessage) async {
        guard !stopped else { return }
        do {
            switch message.type {
            case BridgeMessageType.open: try await open(message)
            case BridgeMessageType.data: try await data(message)
            default: try cancel(message)
            }
        } catch {
            unfinished[message.id] = nil
            respond(message.id, status: -1)
            if error is NoiseError, let session { ended(session, error) }
        }
    }

    private func open(_ message: BridgeMessage) async throws {
        guard let info = Self.object(message.body), let path = info["path"] as? String,
              let verb = info["verb"] as? String else { throw BridgeFailure.transient("请求格式错误") }
        let base = String(path.prefix { $0 != "?" })
        if base == "/passport/reader" || base == "/chat/history" {
            guard verb == "GET" else { throw BridgeFailure.transient("本地请求只支持 GET") }
            // Reading what is already cached needs no Muse connection; new
            // history does, and a turn that lost it fails here rather than hang.
            if base == "/chat/history", session?.ready != true { throw BridgeFailure.transient("Muse 尚未连接") }
            respond(message.id, status: 200, try base == "/chat/history" ? cache.page(path) : cache.readerPage(path))
            return
        }
        guard base == "/chat/stream", let end = info["end"] as? Bool else { throw BridgeFailure.transient("不支持的请求") }
        if !end { unfinished[message.id] = [message] }
        try await ensureSession()
        try start(message)
    }

    /// Starts a request on the current Muse connection.
    private func start(_ message: BridgeMessage) throws {
        guard let info = Self.object(message.body), let path = info["path"] as? String,
              let verb = info["verb"] as? String, let end = info["end"] as? Bool else {
            throw BridgeFailure.transient("请求格式错误")
        }
        guard let session, session.ready else { throw BridgeFailure.transient("Muse 尚未连接") }
        cache.begin()
        session.noteRequest = message.id
        guard session.streams.count < 4, session.streams[message.id] == nil else { throw BridgeFailure.transient("请求过多") }
        let encoding = info["audio"] as? String ?? ""
        guard encoding.isEmpty || encoding == "ima-adpcm-16000-v1" else { throw BridgeFailure.transient("不支持的音频格式") }
        let headers = (info["headers"] as? [[Any]] ?? []).compactMap { pair -> NoiseHeader? in
            guard pair.count == 2, ["content-type", "x-request-id", "x-app-id"].contains("\(pair[0])".lowercased()) else { return nil }
            return NoiseHeader("\(pair[0])", "\(pair[1])")
        }
        let request = try end ? session.transport.encryptHTTPRequest(verb, path, headers: headers)
            : session.transport.startStreamRequest(verb, path, headers: headers)
        session.streams[message.id] = request.streamID
        session.forwards[request.streamID] = (message.id, 0, Data())
        request.frames.forEach { session.frames.yield($0) }
        if !encoding.isEmpty {
            session.audio[message.id] = AudioUpload()
            try session.transport.encryptBodyChunk(streamID: request.streamID, AudioUpload.head)
                .forEach { session.frames.yield($0) }
        }
    }

    private func data(_ message: BridgeMessage) async throws {
        guard unfinished[message.id] != nil else { return try send(message) }
        unfinished[message.id]?.append(message)
        // The connection this request started on is gone: send all of it again.
        if session?.streams[message.id] == nil { try await resend(message.id) } else { try send(message) }
        // The flag byte marks the last piece of the body.
        if message.body.first != 0 { unfinished[message.id] = nil }
    }

    private func resend(_ id: UInt16) async throws {
        try await ensureSession()
        guard let messages = unfinished[id] else { throw BridgeFailure.transient("请求已结束") }
        try start(messages[0])
        try messages.dropFirst().forEach(send)
    }

    private func send(_ message: BridgeMessage) throws {
        guard let session, let stream = session.streams[message.id], let flag = message.body.first else {
            throw BridgeFailure.transient("请求已结束")
        }
        var body = Data(message.body.dropFirst())
        if session.audio[message.id] != nil { body = try session.audio[message.id]!.feed(body, end: flag != 0) }
        try session.transport.encryptBodyChunk(streamID: stream, body, endBody: flag != 0)
            .forEach { session.frames.yield($0) }
    }

    private func cancel(_ message: BridgeMessage) throws {
        unfinished[message.id] = nil
        guard let session, let stream = session.streams.removeValue(forKey: message.id) else { return }
        session.audio[message.id] = nil
        session.forwards[stream] = nil
        try session.transport.encryptReset(streamID: stream).forEach { session.frames.yield($0) }
    }

    // MARK: Messages to the device

    private func emit(_ type: UInt8, _ id: UInt16, _ body: Data) {
        toDevice.yield((type, id, body))
    }

    /// A response in pieces the device can buffer: status and end flag, then bytes.
    private func respond(_ id: UInt16, status: Int, _ data: Data = Data(), end: Bool = true) {
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let part = bytes[offset..<min(offset + Self.chunk, bytes.count)]
            let code = UInt16(bitPattern: Int16(clamping: offset == 0 ? status : 0))
            let last = end && offset + part.count >= bytes.count
            emit(BridgeMessageType.response, id, Data([UInt8(code & 255), UInt8(code >> 8), last ? 1 : 0] + part))
            offset += Self.chunk
        } while offset < bytes.count
    }

    private func update(_ change: (inout BridgeState) -> Void) {
        let before = state
        change(&state)
        if state != before { onState(state) }
    }

    // MARK: SDK token

    /// Saves a token to the device, or clears it when `token` is nil. The
    /// token is never stored or echoed here; the outcome arrives as state.
    public func updateSDKToken(_ token: String?) {
        guard credentials != nil, state.sdkSettingsSupported, !state.sdkSettingsPending else {
            update { $0.sdkSettingsStatus = "请先连接支持设备设置的 Passport" }
            return
        }
        var request: [String: Any] = ["action": token == nil ? "clear" : "set"]
        if let token {
            guard token.wholeMatch(of: /mgst_[A-Za-z0-9_-]{1,58}/) != nil else {
                update { $0.sdkSettingsStatus = "token 应以 mgst_ 开头，最多 63 个字符" }
                return
            }
            request["token"] = token
        }
        settingsRequest &+= 1
        let id = settingsRequest
        update {
            $0.sdkSettingsPending = true
            $0.sdkSettingsStatus = "正在保存到 Passport…"
        }
        emit(BridgeMessageType.sdkSettings, id, Self.json(request))
        Task {
            try? await Task.sleep(for: timing.sdkSettings)
            guard id == settingsRequest, state.sdkSettingsPending else { return }
            update {
                $0.sdkSettingsPending = false
                $0.sdkSettingsStatus = "未收到保存确认，请重连后检查设置状态"
            }
        }
    }

    private func receivedSDKSettings(_ message: BridgeMessage) {
        guard message.id == settingsRequest, state.sdkSettingsPending, let reply = Self.object(message.body) else { return }
        update {
            $0.sdkSettingsPending = false
            guard reply["ok"] as? Bool == true else {
                $0.sdkSettingsStatus = "保存失败，请检查 token 格式并重试"
                return
            }
            $0.sdkTokenConfigured = reply["configured"] as? Bool == true
            $0.sdkSettingsStatus = $0.sdkTokenConfigured ? "已保存到 Passport，设备正在重启…" : "已清除，设备正在重启…"
        }
    }

    // MARK: Muse connection

    /// Reconnects with backoff for as long as the process runs. A suspended
    /// process simply pauses here; a request from the device does not wait for
    /// the backoff, it joins or starts an attempt through `ensureSession`.
    private func keepConnected(afterDrop: Bool) {
        guard keeper == nil, !stopped, permanentFailure == nil else { return }
        keeper = Task {
            var delay = timing.firstRetry
            // A connection that keeps dropping must not be retried in a tight loop.
            if afterDrop { try? await Task.sleep(for: delay) }
            while !Task.isCancelled, !stopped, permanentFailure == nil, session == nil {
                if (try? await ensureSession()) != nil { break }
                try? await Task.sleep(for: delay)
                delay = min(timing.lastRetry, delay * 2)
            }
            keeper = nil
        }
    }

    /// Returns once Muse is connected and subscribed. Concurrent callers share one attempt.
    private func ensureSession() async throws {
        if session?.ready == true { return }
        if credentials == nil { await credentialsArrived() }
        if let permanentFailure { throw BridgeFailure.permanent(permanentFailure) }
        if connecting == nil {
            connecting = Task {
                defer { connecting = nil }
                try await connect()
            }
        }
        try await connecting?.value
    }

    private func connect() async throws {
        update { $0.status = "正在通过手机连接 Muse…" }
        do {
            try await Self.withTimeout(timing.connect) { try await self.establish() }
            update {
                $0.museConnected = true
                $0.status = "Muse 已连接，可以按住 Passport 的 OK 键说话"
            }
        } catch {
            if let session { ended(session, error) } else { failed(error) }
            throw error
        }
    }

    private func establish() async throws {
        guard let credentials else { throw BridgeFailure.transient("尚未取得设备凭据") }
        let vm = try await fetchVM()
        stage = "Muse WebSocket 连接"
        let host = credentials.noiseHost.isEmpty ? "hatch.metaaivm.com" : credentials.noiseHost
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        guard let id = vm.id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "wss://\(host)/v1/noise?vm_id=\(id)") else {
            throw BridgeFailure.transient("Muse 地址无效")
        }
        let socket = try await network.openWebSocket(url, headers: ["Authorization": "Bearer \(vm.token)"])
        guard !stopped, session == nil else {
            socket.close()
            throw CancellationError()
        }
        stage = "Muse 加密握手"
        var handshake = NoiseXXInitiator()
        do {
            try await socket.send(try handshake.writeMessage1())
            _ = try handshake.readMessage2(try await socket.receive())
            // The bearer already authenticated us at the upgrade; message 3
            // carries an empty payload.
            try await socket.send(try handshake.writeMessage3())
        } catch {
            socket.close()
            throw error
        }
        let (frames, continuation) = AsyncStream<Data>.makeStream()
        let session = Session(socket: socket, transport: try handshake.split(), frames: continuation)
        self.session = session
        generation += 1
        // Ciphertext must reach the socket in the order it was encrypted.
        session.tasks.append(Task {
            for await frame in frames {
                do { try await socket.send(frame) } catch { return self.ended(session, error) }
            }
        })
        stage = "Muse 设备注册"
        let control = try session.transport.startStreamRequest("POST", "/link-control")
        session.controlStream = control.streamID
        control.frames.forEach { session.frames.yield($0) }
        session.registerID = UUID().uuidString.lowercased()
        try sendControl(session, [
            "type": "req", "id": session.registerID, "method": "link.register",
            "params": [
                "node_id": credentials.nodeID, "display_name": "FoloToy AI Passport", "platform": "esp32",
                "version": credentials.version.isEmpty ? "0.1" : credentials.version, "device_family": "link",
                "model_id": "esp-link", "is_wakeup_supported": false, "commands_v2": [String: Any](),
            ] as [String: Any],
        ])
        while !session.ready {
            let message = try await socket.receive()
            guard self.session === session else { throw CancellationError() }
            try process(session, message)
        }
        session.tasks.append(Task {
            do {
                while true {
                    let message = try await socket.receive()
                    guard self.session === session else { return }
                    try self.process(session, message)
                }
            } catch {
                self.ended(session, error)
            }
        })
    }

    private func sendControl(_ session: Session, _ message: [String: Any]) throws {
        let body = [UInt8](Self.json(message))
        let length = (0..<4).map { UInt8(truncatingIfNeeded: body.count >> (8 * $0)) }
        try session.transport.encryptBodyChunk(streamID: session.controlStream, Data(length + body))
            .forEach { session.frames.yield($0) }
    }

    /// Handles one message from the VM. Synchronous, so frames never interleave.
    private func process(_ session: Session, _ message: Data) throws {
        guard let decrypted = try session.transport.decryptFrame(message) else { return }
        let (status, data, end): (Int, Data, Bool)
        switch decrypted.frame {
        case let .response(code, _, body, last): (status, data, end) = (Int(code), body, last)
        case let .bodyChunk(body, last): (status, data, end) = (0, body, last)
        case .reset: (status, data, end) = (-1, Data(), true)
        }
        if decrypted.streamID == session.controlStream {
            guard status >= 0, status < 400 else {
                throw BridgeFailure.transient(status == 403 ? "Muse 拒绝设备会话" : "Muse 会话已结束")
            }
            try control(session, data)
            if end { throw BridgeFailure.transient("Muse 会话已结束") }
        } else if decrypted.streamID == session.subscriptionStream {
            guard status >= 0 else { throw BridgeFailure.transient("Muse 重置了回复订阅") }
            if case .response = decrypted.frame {
                guard status == 200 else {
                    let text = "Muse 拒绝回复订阅 (HTTP \(status))"
                    throw status == 401 || status == 403 ? BridgeFailure.permanent(text) : BridgeFailure.transient(text)
                }
                session.ready = true
            }
            try cache.feed(data)
            if end { throw BridgeFailure.transient("Muse 回复订阅已结束") }
        } else if var forward = session.forwards[decrypted.streamID] {
            forward.received += data.count
            if forward.request == session.noteRequest, status >= 0 {
                if forward.ack.count + data.count <= 4096 { forward.ack += data }
                if end, let ack = Self.object(forward.ack) {
                    let result = ack["result"] as? [String: Any] ?? ack
                    cache.note(result["message_id"] as? String ?? "", replyTo: result["reply_to_message_id"] as? String ?? "")
                }
            }
            guard forward.received <= Self.responseLimit else { throw BridgeFailure.transient("Muse 响应过大") }
            respond(forward.request, status: status, data, end: end)
            unfinished[forward.request] = nil
            session.forwards[decrypted.streamID] = end ? nil : forward
            if end {
                session.streams[forward.request] = nil
                session.audio[forward.request] = nil
            }
        }
    }

    /// The control stream carries JSON messages, each prefixed with a u32 length.
    private func control(_ session: Session, _ data: Data) throws {
        session.controlBuffer += data
        while session.controlBuffer.count >= 4 {
            let length = (0..<4).reduce(0) { $0 | Int(session.controlBuffer[$1]) << (8 * $1) }
            guard length <= 4 * 1024 * 1024 else { throw BridgeFailure.transient("Muse 控制消息过大") }
            guard session.controlBuffer.count >= 4 + length else { break }
            let raw = Data(session.controlBuffer[4..<4 + length])
            session.controlBuffer.removeFirst(4 + length)
            guard let message = Self.object(raw) else { continue }
            if message["id"] as? String == session.registerID, message["method"] == nil {
                if let error = message["error"], !(error is NSNull) {
                    throw BridgeFailure.transient("Muse 拒绝设备注册，请检查设备的账号绑定")
                }
                stage = "Muse 回复订阅"
                let request = try session.transport.encryptHTTPRequest("POST", "/chat/subscribe", body: Data("{}".utf8), headers: [
                    NoiseHeader("Content-Type", "application/json"), NoiseHeader("Accept", "application/x-ndjson"),
                    NoiseHeader("x-app-id", "hatch-web"),
                ])
                session.subscriptionStream = request.streamID
                cache.resubscribed()
                request.frames.forEach { session.frames.yield($0) }
            } else if let event = message["event"] as? String, event == "link.unpaired" || event == "node.unpaired" {
                throw BridgeFailure.permanent("Muse 已移除此设备，请在 Muse App 中重新绑定")
            } else if message["method"] as? String == "link.invoke", let id = message["id"], !(id is NSNull) {
                try sendControl(session, ["method": "link.result", "id": id, "error": [
                    "code": "unsupported", "message": "Remote commands are not supported",
                ]])
            }
        }
    }

    private func close(_ session: Session) {
        session.frames.finish()
        session.tasks.forEach { $0.cancel() }
        session.socket.close()
    }

    /// The Muse connection is gone. Requests in flight fail; the device stays
    /// ready unless the failure is permanent.
    private func ended(_ session: Session, _ error: Error) {
        guard self.session === session else { return }
        self.session = nil
        close(session)
        // A request still being sent has not been answered; `data` sends it again.
        session.streams.keys.filter { unfinished[$0] == nil }.forEach { respond($0, status: -1) }
        failed(error)
    }

    private func failed(_ error: Error) {
        guard !stopped, !(error is CancellationError) else { return }
        if case let BridgeFailure.permanent(text) = error {
            permanentFailure = text
            update {
                $0.museConnected = false
                $0.status = text
            }
            emit(BridgeMessageType.error, 0, Data(text.utf8))
            return
        }
        update {
            $0.museConnected = false
            $0.status = "\(stage)失败：\(failureReason(error))；正在重试"
        }
        keepConnected(afterDrop: true)
    }

    // MARK: Muse account API

    private func api(_ method: String, _ path: String, auth: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let root = credentials?.apiURL.isEmpty == false ? credentials!.apiURL : "https://api.muse.ai"
        guard let url = URL(string: String(root.reversed().drop { $0 == "/" }.reversed()) + path), url.scheme == "https" else {
            throw BridgeFailure.transient("需要加密的 Muse 地址")
        }
        let (status, data) = try await network.http(method, url, headers: [
            "Authorization": auth, "X-API-Version": Self.apiVersion, "User-Agent": userAgent,
        ], body: body.map(Self.json))
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            if status == 200 { throw BridgeFailure.transient("Muse API 返回了无效的 JSON 响应") }
            return (status, [:])
        }
        guard let payload = parsed as? [String: Any] else { throw BridgeFailure.transient("Muse API 返回了无效的响应格式") }
        return (status, payload)
    }

    private func fetchVM() async throws -> (id: String, token: String) {
        guard var credentials else { throw BridgeFailure.transient("尚未取得设备凭据") }
        stage = "Muse 账号信息获取"
        var (status, payload) = try await api("GET", "/fetch_vms", auth: "Bearer \(credentials.accessToken)")
        if status == 401 {
            let raw = credentials.refreshToken.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            guard !raw.isEmpty else { throw BridgeFailure.permanent("账号绑定已过期，请在 Muse App 中重新绑定") }
            var body = ["device_id": credentials.deviceID]
            if !credentials.sdkToken.isEmpty { body["sdk_token"] = credentials.sdkToken }
            stage = "Muse 设备凭据更新"
            let (code, reply) = try await api("POST", "/device_token/refresh", auth: "Bearer hatch_refresh:\(raw)", body: body)
            guard code == 200 else {
                throw code == 401 || code == 403
                    ? BridgeFailure.permanent("Muse 凭据更新失败 (HTTP \(code))，请在 Muse App 中检查账号绑定")
                    : BridgeFailure.transient("Muse 凭据更新 HTTP \(code)")
            }
            let tokens = reply["payload"] as? [String: Any] ?? reply
            guard let access = tokens["access_token"] as? String, !access.isEmpty,
                  let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
                throw BridgeFailure.transient("Muse 凭据响应不完整")
            }
            // The device commits the rotated credentials before they are used.
            stage = "Passport 凭据保存"
            emit(BridgeMessageType.tokens, 0, Self.json(["access_token": access, "refresh_token": refresh]))
            guard await tokenCommitted() else { throw BridgeFailure.transient("Passport 无法保存更新后的凭据") }
            credentials.accessToken = access
            credentials.refreshToken = refresh
            if self.credentials != nil { self.credentials = credentials }
            stage = "Muse 账号信息获取"
            (status, payload) = try await api("GET", "/fetch_vms", auth: "Bearer \(access)")
        }
        guard status == 200 else { throw BridgeFailure.transient("Muse API HTTP \(status)") }
        guard let list = payload["vm_list"] as? [Any] else { throw BridgeFailure.transient("Muse API 响应缺少有效的 vm_list") }
        let candidates = list.compactMap { $0 as? [String: Any] }.filter {
            !($0["vm_id"] as? String ?? "").isEmpty && !($0["vm_auth_token"] as? String ?? "").isEmpty
        }
        guard let chosen = candidates.first(where: { $0["vm_id"] as? String == credentials.vmID })
            ?? candidates.first(where: { $0["default"] as? Bool == true }) ?? candidates.first else {
            throw BridgeFailure.transient("账号没有可用的 Muse VM，请在 Muse App 中检查账号状态")
        }
        return (chosen["vm_id"] as? String ?? "", chosen["vm_auth_token"] as? String ?? "")
    }

    /// A relaunched app is handed the turn that woke it before the device has
    /// answered the greeting; the credentials are then moments away.
    private func credentialsArrived() async {
        let timeout = Task {
            try? await Task.sleep(for: timing.credentials)
            if !Task.isCancelled { resolveCredentialsWait() }
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { credentialsWaiters.append($0) }
    }

    private func resolveCredentialsWait() {
        credentialsWaiters.forEach { $0.resume() }
        credentialsWaiters = []
    }

    private func tokenCommitted() async -> Bool {
        let timeout = Task {
            try? await Task.sleep(for: timing.tokenCommit)
            if !Task.isCancelled { resolveTokenCommit(false) }
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { tokenWaiter = $0 }
    }

    private func resolveTokenCommit(_ ok: Bool) {
        tokenWaiter?.resume(returning: ok)
        tokenWaiter = nil
    }

    // MARK: Helpers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
