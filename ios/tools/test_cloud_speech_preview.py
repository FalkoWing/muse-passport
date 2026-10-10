"""Run the real preview error path without networking or playing audio."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CloudSpeechPreviewTest(unittest.TestCase):
    def test_cloud_errors_show_the_service_code_not_a_voice_pack_hint(self):
        player = (ROOT / 'ios/MusePassport/Sources/SpeechPlayer.swift').read_text()
        preview = player[player.index('    func preview(useCloud:'):player.rfind('\n}')]
        cloud = (ROOT / 'ios/PassportBridge/Sources/PassportBridge/CloudSpeech.swift').read_text()
        definitions = cloud[:cloud.index('/// Downloads')]
        speech = (ROOT / 'ios/PassportBridge/Sources/PassportBridge/Speech.swift').read_text()
        failure = next(line for line in speech.splitlines() if line.startswith('public enum SpeechFailure'))
        harness = definitions + failure + r'''
@MainActor final class AVAudioSession {
    enum Category { case playback }; enum Mode { case spokenAudio }
    enum Options { case notifyOthersOnDeactivation }
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    func setCategory(_ category: Category, mode: Mode) throws {}
    func setActive(_ active: Bool, options: Options? = nil) throws {}
}
@MainActor final class AVAudioPlayer {
    static var created = 0
    var duration = 0.0
    init(data: Data) throws { Self.created += 1 }
    func play() {} ; func stop() {}
}
@MainActor final class SpeechPlayer {
    var previewing = false, status = "", run: Int?
    var previewTask: Task<Void, Never>?, player: AVAudioPlayer?
    var failure: Error = SpeechFailure.cloud(45000000)
    func cloudPCM(_ text: String, consume: @MainActor ([Int16]) async throws -> Void) async throws { throw failure }
    func systemPCM(_ text: String) async throws -> [Int16] { throw failure }
''' + preview + r'''
    static func verify() async {
        let player = SpeechPlayer()
        for (error, expected) in [
            (SpeechFailure.cloud(45000000) as Error, "45000000"),
            (URLError(.timedOut) as Error, "网络"),
            (SpeechFailure.incomplete as Error, "完整"),
            (CloudSpeechRequestFailure.http(403) as Error, "HTTP 403"),
            (CloudSpeechRequestFailure.configuration as Error, "音色 ID"),
        ] {
            player.failure = error; player.preview(useCloud: true)
            await player.previewTask?.value
            precondition(player.status.contains(expected), "cloud preview lost error: " + player.status)
            precondition(!player.status.contains("声包") && !player.previewing)
        }
        player.preview(useCloud: false); await player.previewTask?.value
        precondition(player.status.contains("本机") && player.status.contains("声包"))
        precondition(AVAudioPlayer.created == 0)
        print("Cloud preview: error code and source-specific hints PASS; no audio played")
    }
}
@main struct Verify { static func main() async { await SpeechPlayer.verify() } }
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'Verify.swift').write_text(harness)
            subprocess.run(['swiftc', '-parse-as-library', str(path / 'Verify.swift'), '-o', str(path / 'verify')], check=True)
            subprocess.run([str(path / 'verify')], check=True)


if __name__ == '__main__':
    unittest.main()
