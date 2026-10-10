@preconcurrency import AVFoundation
import Foundation
import PassportBridge
import UIKit
import Observation

private enum VoiceError: Error { case unavailable, timeout, disconnected, cancelled }

/// AVSpeechSynthesizer callbacks may use another thread. Collect only one
/// bounded sentence; the whole reply never becomes a PCM allocation.
private final class SpeechCapture: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var rate = 0.0
    var continuation: CheckedContinuation<([Float], Double), Error>?
    private var finished = false
    func install(_ continuation: CheckedContinuation<([Float], Double), Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func finish(_ error: Error? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let result = (samples, rate)
        samples = []
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: result) }
    }
    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { finish(VoiceError.unavailable); return }
        if pcm.frameLength == 0 { finish(); return }
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard pcm.format.commonFormat == .pcmFormatFloat32, let channels = pcm.floatChannelData,
              samples.count + Int(pcm.frameLength) <= 1_000_000,
              rate == 0 || rate == pcm.format.sampleRate else {
            lock.unlock(); finish(VoiceError.unavailable); return
        }
        rate = pcm.format.sampleRate
        for i in 0..<Int(pcm.frameLength) {
            var value: Float = 0
            for c in 0..<Int(pcm.format.channelCount) { value += channels[c][i] }
            samples.append(value / Float(pcm.format.channelCount))
        }
        lock.unlock()
    }
}

@MainActor @Observable
final class SpeechPlayer {
    private(set) var status = ""
    private(set) var previewing = false
    var systemVoiceAvailable: Bool { AVSpeechSynthesisVoice(language: "zh-CN") != nil }
    private let synth = AVSpeechSynthesizer()
    private var capture: SpeechCapture?
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var run: Run?
    private var previewTask: Task<Void, Never>?
    private final class Run {
        var follow = false
        let id: UInt32
        let send: @MainActor (Data) async -> Bool
        var limit: UInt32, frame: UInt32 = 0
        var state: UInt8 = 0
        init(id: UInt32, limit: UInt32, send: @escaping @MainActor (Data) async -> Bool) {
            self.id = id; self.limit = min(8, limit); self.send = send
        }
    }
    func receive(_ command: SpeechCommand, send: @escaping @MainActor (Data) async -> Bool) {
        switch command {
        case let .request(id, text, limit):
            let previous = task
            let previousPreview = previewTask
            stop()
            let run = Run(id: id, limit: limit, send: send); self.run = run
            task = Task { await previous?.value; await previousPreview?.value; await speak(text, run: run) }
        case let .followRequest(id, text, limit):
            let previous = task
            let previousPreview = previewTask
            stop()
            let run = Run(id: id, limit: limit, send: send); run.follow = true; self.run = run
            task = Task { await previous?.value; await previousPreview?.value; await speak(text, run: run) }
        case let .status(status):
            guard let run, run.id == status.session else { return }
            run.limit = status.limit; run.state = status.state
            if [2,3,5].contains(status.state) { task?.cancel(); capture?.finish(CancellationError()); synth.stopSpeaking(at: .immediate) }
        }
    }
    func stop() {
        task?.cancel(); task = nil; run = nil
        previewTask?.cancel(); player?.stop(); player = nil
        capture?.finish(CancellationError()); capture = nil; synth.stopSpeaking(at: .immediate)
    }
    private func check(_ run: Run) throws {
        try Task.checkCancellation()
        guard self.run === run, ![2,3,5].contains(run.state) else { throw VoiceError.cancelled }
    }
    private func send(_ body: Data, run: Run) async throws {
        try check(run)
        guard await run.send(body) else { throw VoiceError.disconnected }
    }
    private func packet(_ opus: Data, run: Run, origin: UInt32 = .max) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while run.frame >= run.limit {
            try check(run)
            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        var payload = opus
        if run.follow {
            payload = Data((0..<4).map { UInt8(truncatingIfNeeded: origin >> ($0 * 8)) }) + opus
        }
        try await send(speechPacket(session: run.id, frame: run.frame, kind: run.follow ? 5 : 0, opus: payload), run: run)
        run.frame += 1
    }
    private func pcm(_ samples: [Int16], encoder: SpeechEncoder, run: Run, origin: UInt32 = .max) async throws {
        for offset in stride(from: 0, to: samples.count, by: 960) {
            for frame in try encoder.feedLocated(Array(samples[offset..<min(offset + 960, samples.count)]), origin: origin) {
                try await packet(frame.opus, run: run, origin: frame.origin)
            }
        }
    }
    private func speak(_ text: String, run: Run) async {
        var pendingCloud: Task<[Int16], Error>?
        defer { pendingCloud?.cancel() }
        var background: UIBackgroundTaskIdentifier = .invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "回复朗读") { [weak self] in
            Task { @MainActor in
                if background != .invalid {
                    UIApplication.shared.endBackgroundTask(background); background = .invalid
                }
                guard let self, self.run === run else { return }
                self.stop(); self.status = "后台朗读已停止，请重新打开伴侣 App"
                _ = await run.send(speechPacket(session: run.id, frame: run.frame, kind: 4))
            }
        }
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            if self.run === run { self.run = nil; task = nil }
        }
        var noSpeech = false
        do {
            guard !text.isEmpty else { throw VoiceError.unavailable }
            let segments = speechSegments(text)
            let sentences = segments.map(\.text)
            noSpeech = sentences.isEmpty
            if !noSpeech {
                var encoder = try SpeechEncoder()
                var cloud = SpeechSettings.shared.useCloud
                var index = 0
                while index < sentences.count {
                    try check(run)
                    do {
                        if cloud {
                            let download = pendingCloud ?? Task { try await self.cloudSamples(sentences[index]) }
                            pendingCloud = download
                            let samples = try await withTaskCancellationHandler {
                                try await download.value
                            } onCancel: { download.cancel() }
                            try check(run)
                            // Keep only one sentence ahead. Its download overlaps
                            // device-paced playback instead of adding a gap after it.
                            if index + 1 < sentences.count {
                                let next = sentences[index + 1]
                                pendingCloud = Task { try await self.cloudSamples(next) }
                            } else { pendingCloud = nil }
                            try await pcm(samples, encoder: encoder, run: run, origin: UInt32(segments[index].origin))
                        } else { try await pcm(systemPCM(sentences[index]), encoder: encoder, run: run, origin: UInt32(segments[index].origin)) }
                        index += 1
                    } catch {
                        pendingCloud?.cancel(); pendingCloud = nil
                        try check(run)
                        guard cloud else { throw error }
                        /* The device arbitrates this race after queued audio and
                         * the actual I2S writes, so a late STARTED cannot fool us. */
                        run.state = 0
                        try await send(speechPacket(session: run.id, frame: run.frame, kind: 2), run: run)
                        let deadline = ContinuousClock.now + .seconds(5)
                        while run.state != 4 {
                            try check(run)
                            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        run.frame = 0; run.limit = 0; run.state = 0
                        try await send(speechPacket(session: run.id, frame: 0, kind: 3), run: run)
                        encoder = try SpeechEncoder(); cloud = false; index = 0
                        status = "云端未开播，已切换手机内置语音"
                    }
                }
                for frame in try encoder.feedLocated([], origin: .max, end: true) { try await packet(frame.opus, run: run, origin: frame.origin) }
            }
            try await send(speechPacket(session: run.id, frame: run.frame, kind: 1), run: run)
            // Keep cancellation and the background task alive until device drain.
            let deadline = ContinuousClock.now + .seconds(15)
            while run.state < 2 {
                try check(run)
                guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
            if run.state == 2 { status = noSpeech ? "无可朗读内容，文字仍可阅读" : "朗读完成" }
            else if run.state == 5 { status = "朗读失败，文字仍可阅读" }
            else { status = "朗读已停止" }
        } catch {
            if run.state == 2 { status = noSpeech ? "无可朗读内容，文字仍可阅读" : "朗读完成" }
            else if run.state == 5 { status = "朗读失败，文字仍可阅读" }
            else if error is CancellationError || run.state == 3 { status = "朗读已停止" }
            else { status = "朗读失败，文字仍可阅读" }
            if self.run === run, ![2,3,5].contains(run.state) {
                _ = await run.send(speechPacket(session: run.id, frame: run.frame, kind: 4))
            }
        }
    }
    private func cloudSamples(_ text: String) async throws -> [Int16] {
        var samples: [Int16] = []
        try await cloudPCM(text) { samples = $0 }
        return samples
    }
    private func systemPCM(_ text: String) async throws -> [Int16] {
        try Task.checkCancellation()
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else { throw VoiceError.unavailable }
        let capture = SpeechCapture(); self.capture = capture
        defer { if self.capture === capture { self.capture = nil } }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { capture.finish(VoiceError.timeout) }
        }
        defer { timeout.cancel() }
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        let (samples, rate) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard capture.install(continuation) else { return }
                synth.write(utterance) { capture.receive($0) }
            }
        } onCancel: { capture.finish(CancellationError()) }
        guard rate > 0, !samples.isEmpty,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * 16000 / rate + 128)),
              let converter = AVAudioConverter(from: source, to: target) else { throw VoiceError.unavailable }
        input.frameLength = input.frameCapacity
        input.floatChannelData![0].update(from: samples, count: samples.count)
        var supplied = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, flag in
            if supplied { flag.pointee = .endOfStream; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        guard result != .error, let channel = output.int16ChannelData else { throw VoiceError.unavailable }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
    private func cloudPCM(_ text: String, consume: @MainActor ([Int16]) async throws -> Void) async throws {
        let settings = SpeechSettings.shared, secret = try settings.secret()
        guard !secret.isEmpty, !settings.voice.isEmpty, !settings.resource.isEmpty else { throw CloudSpeechRequestFailure.configuration }
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        if settings.legacy {
            guard !settings.appID.isEmpty else { throw CloudSpeechRequestFailure.configuration }
            request.setValue(settings.appID, forHTTPHeaderField: "X-Api-App-Id")
            request.setValue(secret, forHTTPHeaderField: "X-Api-Access-Key")
        } else { request.setValue(secret, forHTTPHeaderField: "X-Api-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "muse-passport"], "req_params": ["text": text, "speaker": settings.voice,
                "audio_params": ["format": "pcm", "sample_rate": 16000]] as [String: Any]])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpStatus == 200 else { throw CloudSpeechRequestFailure.http(httpStatus) }
        var iterator = stream.makeAsyncIterator()
        try await consumeCloudSpeechSentence(next: { try await iterator.next() }, consume: consume)
    }
    func preview(useCloud: Bool) {
        guard !previewing, run == nil else { status = "请先停止设备朗读"; return }
        previewing = true
        previewTask = Task {
            defer {
                previewing = false; previewTask = nil
                player?.stop(); player = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            do {
                let phrase = "你好，我是 Muse。这是一段语音试听。"
                var samples: [Int16] = []
                if useCloud { try await cloudPCM(phrase) { samples += $0 } }
                else { samples = try await systemPCM(phrase) }
                var wav = Data("RIFF".utf8)
                func number(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
                wav += number(UInt32(samples.count * 2 + 36)); wav += Data("WAVEfmt ".utf8)
                wav += number(16); wav += Data([1,0,1,0]); wav += number(16000); wav += number(32000)
                wav += Data([2,0,16,0]); wav += Data("data".utf8); wav += number(UInt32(samples.count * 2))
                for sample in samples { let n = UInt16(bitPattern: sample); wav.append(UInt8(n & 255)); wav.append(UInt8(n >> 8)) }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(data: wav); player?.play()
                status = "正在手机上试听"
                try await Task.sleep(for: .seconds(player?.duration ?? 0))
                player = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                status = "试听完成"
            } catch {
                if !(error is CancellationError) {
                    status = useCloud ? "云端试听失败：" + cloudSpeechFailureDescription(error)
                        : "本机试听失败，请检查中文声包或手机音频设置"
                }
            }
        }
    }
}
