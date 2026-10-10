"""Compile real SpeechPlayer session methods against transport/synthesis fakes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EmptySpeechTest(unittest.TestCase):
    def test_empty_replies_end_without_synthesis_or_encoder(self):
        player = (ROOT / 'ios/MusePassport/Sources/SpeechPlayer.swift').read_text()
        speech = (ROOT / 'ios/PassportBridge/Sources/PassportBridge/Speech.swift').read_text()
        pure = speech[speech.index('public func speechPacket'):speech.index('/// One encoder')]
        run = player[player.index('    private final class Run'):player.index('    func receive', player.index('    private final class Run'))]
        methods = player[player.index('    private func check'):player.index('    private func systemPCM')]
        harness = r'''
import Foundation
private enum VoiceError: Error { case unavailable, timeout, disconnected, cancelled, cloud }
struct UIBackgroundTaskIdentifier: Equatable { let value: Int; static let invalid = Self(value: -1) }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var active = 0
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {active += 1; return .init(value: 1)}
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {active -= 1}
}
@MainActor final class SpeechSettings {static let shared = SpeechSettings(); var useCloud = false}
@MainActor final class SpeechEncoder {
    static var created = 0
    init() throws {Self.created += 1}
    func feed(_ samples: [Int16], end: Bool = false) throws -> [Data] { [Data(repeating: 0, count: 120)] }
    func feedLocated(_ samples: [Int16], origin: UInt32, end: Bool = false) throws -> [SpeechAudioFrame] {
        [SpeechAudioFrame(opus: Data(repeating: 0, count: 120), origin: origin)]
    }
}
''' + pure + r'''
@MainActor final class SpeechPlayer {
    var status = "", synthesized = 0
    var downloads: [String] = [], cancelledDownloads: [String] = []
    var heldDownload: String?, failedDownload: String?
    var task: Task<Void, Never>?, run: Run?
    func stop() {task?.cancel(); run = nil}
''' + run.replace('private final class Run', 'final class Run') + methods + r'''
    func systemPCM(_ text: String) async throws -> [Int16] {synthesized += 1; return [1]}
    func cloudPCM(_ text: String, consume: @MainActor ([Int16]) async throws -> Void) async throws {
        synthesized += 1; downloads.append(text)
        if text == heldDownload {
            do {try await Task.sleep(for: .seconds(10))}
            catch {cancelledDownloads.append(text); throw error}
        }
        if text == failedDownload {throw VoiceError.cloud}
        try await consume(Array(repeating: 1, count: 1920))
    }
    static func verify() async {
        for cloud in [false, true] {
            SpeechSettings.shared.useCloud = cloud
            for text in ["```\ncode\n```", "![图](https://x/a_(b))", "⏰👨‍👩‍👧‍👦", "！！！", " \n "] {
                for state: UInt8 in [2,3,5] {
                    let player = SpeechPlayer()
                    var writes: [Data] = []
                    let run = Run(id: 7, limit: 8) { body in
                        writes.append(body)
                        // Feedback can arrive while awaiting send or during drain.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(30))
                            precondition(player.run != nil)
                            player.run?.state = state; player.task?.cancel()
                        }
                        return true
                    }
                    player.run = run; SpeechEncoder.created = 0
                    let task = Task { await player.speak(text, run: run) }; player.task = task
                    await task.value
                    precondition(writes == [speechPacket(session: 7, frame: 0, kind: 1)])
                    precondition(SpeechEncoder.created == 0 && player.synthesized == 0 && player.run == nil)
                    let expected = state == 2 ? "无可朗读内容，文字仍可阅读" : state == 3 ? "朗读已停止" : "朗读失败，文字仍可阅读"
                    precondition(player.status == expected, player.status)
                    precondition(UIApplication.shared.active == 0)
                }
            }
        }
        let zeroCredit = SpeechPlayer()
        let zero = Run(id: 7, limit: 0) {body in
            precondition(body == speechPacket(session: 7, frame: 0, kind: 1))
            zeroCredit.run?.state = 2; return true
        }
        zeroCredit.run = zero; SpeechEncoder.created = 0
        await zeroCredit.speak("⏰", run: zero)
        precondition(SpeechEncoder.created == 0 && zeroCredit.synthesized == 0 && zeroCredit.status == "无可朗读内容，文字仍可阅读")
        let failed = SpeechPlayer(); var writes: [Data] = []
        let failure = Run(id: 7, limit: 0) {writes.append($0); return false}; failed.run = failure
        await failed.speak("⏰", run: failure)
        precondition(failed.status == "朗读失败，文字仍可阅读" && writes.map {Array($0)[8]} == [1,4])
        let stopped = SpeechPlayer(), cancellation = Run(id: 7, limit: 0) {_ in preconditionFailure("stopped sent data")}
        stopped.run = cancellation; cancellation.state = 3
        await stopped.speak("⏰", run: cancellation); precondition(stopped.status == "朗读已停止")
        let normal = SpeechPlayer(); writes = []; SpeechEncoder.created = 0
        let audio = Run(id: 7, limit: 8) {body in
            writes.append(body); if Array(body)[8] == 1 {normal.run?.state = 2}; return true
        }
        normal.run = audio; SpeechSettings.shared.useCloud = false
        await normal.speak("正文。", run: audio)
        precondition(SpeechEncoder.created == 1 && normal.synthesized == 1 && normal.status == "朗读完成")
        precondition(writes.map {Array($0)[8]} == [0,0,1])
        precondition(UIApplication.shared.active == 0)
        // Real speak must request the next sentence while current PCM is still
        // held by paced BLE. Gates are event ordering, independent of network time.
        let prefetched = SpeechPlayer(); var audioFrames = 0
        SpeechSettings.shared.useCloud = true
        let pipeline = Run(id: 9, limit: 8) {body in
            if Array(body)[8] == 0 {
                for _ in 0..<20 {await Task.yield()}
                if audioFrames == 0 {
                    precondition(prefetched.downloads == ["第一句。", "第二句；"], "second synthesis starts only after first playback: \(prefetched.downloads)")
                }
                if audioFrames == 2 {
                    precondition(prefetched.downloads == ["第一句。", "第二句；", "第三句。"])
                }
                audioFrames += 1; prefetched.run?.limit += 1
            }
            if Array(body)[8] == 1 {prefetched.run?.state = 2}
            return true
        }
        prefetched.run = pipeline
        await prefetched.speak("第一句。第二句；第三句。", run: pipeline)
        precondition(prefetched.status == "朗读完成" && prefetched.synthesized == 3)
        let interrupted = SpeechPlayer(); interrupted.heldDownload = "第二句；"
        let interruptedRun = Run(id: 10, limit: 8) {body in
            if Array(body)[8] == 0 {
                for _ in 0..<20 {await Task.yield()}
                interrupted.run?.state = 3; interrupted.task?.cancel()
            }
            return true
        }
        interrupted.run = interruptedRun
        let interruptedTask = Task {await interrupted.speak("第一句。第二句；", run: interruptedRun)}
        interrupted.task = interruptedTask; await interruptedTask.value
        for _ in 0..<20 {await Task.yield()}
        precondition(interrupted.status == "朗读已停止" && interrupted.cancelledDownloads == ["第二句；"])
        // Cancelling while awaiting network must also cancel the unstructured
        // download task, rather than hold a new reply behind the HTTP timeout.
        let waiting = SpeechPlayer(); waiting.heldDownload = "第一句。"
        let waitingRun = Run(id: 11, limit: 8) {_ in preconditionFailure("cancelled network sent audio")}
        waiting.run = waitingRun
        let waitingTask = Task {await waiting.speak("第一句。", run: waitingRun)}; waiting.task = waitingTask
        while waiting.downloads.isEmpty {await Task.yield()}
        waiting.run?.state = 3; waitingTask.cancel(); await waitingTask.value
        precondition(waiting.cancelledDownloads == ["第一句。"] && waiting.status == "朗读已停止")
        // A failed prefetched sentence is handled in order, after current audio.
        // Device rejection once started must not switch sources or skip text.
        let lateFailure = SpeechPlayer(); lateFailure.failedDownload = "第二句；"
        var lateWrites: [UInt8] = []
        let lateRun = Run(id: 12, limit: 8) {body in
            let kind = Array(body)[8]; lateWrites.append(kind)
            if kind == 2 {lateFailure.run?.state = 5}
            return true
        }
        lateFailure.run = lateRun
        await lateFailure.speak("第一句。第二句；第三句。", run: lateRun)
        precondition(lateWrites == [0,0,2] && lateFailure.synthesized == 2 && lateFailure.status == "朗读失败，文字仍可阅读")
        let earlyFailure = SpeechPlayer(); earlyFailure.failedDownload = "第一句。"
        var earlyWrites: [UInt8] = []
        let earlyRun = Run(id: 13, limit: 8) {body in
            let kind = Array(body)[8]; earlyWrites.append(kind)
            if kind == 2 {earlyFailure.run?.state = 4}
            if kind == 3 {earlyFailure.run?.limit = 8}
            if kind == 1 {earlyFailure.run?.state = 2}
            return true
        }
        earlyFailure.run = earlyRun
        await earlyFailure.speak("第一句。第二句；", run: earlyRun)
        precondition(earlyWrites == [2,3,0,0,0,1] && earlyFailure.downloads == ["第一句。"])
        precondition(earlyFailure.synthesized == 3 && earlyFailure.status == "朗读完成")
        precondition(UIApplication.shared.active == 0)
        print("iOS real speak: empty end, drain, failure, one-sentence lookahead and download cancellation passed")
    }
}
@main struct Tests {static func main() async {await SpeechPlayer.verify()}}
'''
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / 'EmptySpeech.swift'
            exe = Path(directory) / 'test'
            swift.write_text(harness)
            built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(exe)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
