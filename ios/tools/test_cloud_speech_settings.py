"""Exercise the real settings with isolated preferences and no production keychain access."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]


class CloudSpeechSettingsTest(unittest.TestCase):
    def test_defaults_migrate_once_and_custom_ids_survive_reopening(self):
        source = (ROOT / 'ios/MusePassport/Sources/SpeechSettings.swift').read_text()
        source = source.replace('UserDefaults.standard', 'testDefaults')
        source = source.replace('io.github.falkowing.musepassport.tts', 'io.github.falkowing.musepassport.test.' + uuid.uuid4().hex)
        harness = '''
import Foundation
let suite = "MusePassport.CloudSettingsTest." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suite)!
''' + source + '''
@main struct Verify {
    @MainActor static func main() {
        defer { testDefaults.removePersistentDomain(forName: suite) }
        let fresh = SpeechSettings()
        precondition(fresh.voice == CloudSpeechCatalog.defaultVoiceID && !fresh.cloud)
        precondition(fresh.voice == "ICL_uranus_zh_female_keainvsheng_tob", "default must match current TTS 2.0 catalog")
        precondition(CloudSpeechCatalog.voices(for: fresh.resource).contains { $0.id == "ICL_uranus_zh_female_tiaopigongzhu_tob" })
        for (old, current) in [
            ("ICL_zh_female_keainvsheng_tob", "ICL_uranus_zh_female_keainvsheng_tob"),
            ("ICL_zh_female_tiaopigongzhu_tob", "ICL_uranus_zh_female_tiaopigongzhu_tob"),
            ("zh_female_santongyongns_saturn_bigtts", "zh_female_liuchangnv_uranus_bigtts"),
            ("zh_male_ruyayichen_saturn_bigtts", "zh_male_ruyayichen_uranus_bigtts"),
            ("zh_male_dayi_saturn_bigtts", "zh_male_dayi_uranus_bigtts"),
        ] {
            testDefaults.set(old, forKey: "speech.voice")
            let corrected = SpeechSettings()
            precondition(corrected.voice == current, "outdated preset was not repaired")
            precondition(SpeechSettings().voice == current)
            precondition(CloudSpeechCatalog.initialVoice(resource: "seed-custom-concurr", saved: old, migrateDefault: true) == old)
        }
        testDefaults.removePersistentDomain(forName: suite)
        testDefaults.set(CloudSpeechCatalog.previousDefaultVoiceID, forKey: "speech.voice")
        let migrated = SpeechSettings()
        precondition(migrated.voice == CloudSpeechCatalog.defaultVoiceID)
        precondition(migrated.save(cloud: false, legacy: false, appID: "", resource: CloudSpeechCatalog.modelID,
                                  voice: CloudSpeechCatalog.previousDefaultVoiceID, secret: ""))
        precondition(SpeechSettings().voice == CloudSpeechCatalog.previousDefaultVoiceID)
        precondition(migrated.save(cloud: false, legacy: false, appID: "", resource: " seed-custom-concurr ",
                                  voice: " S_custom_voice ", secret: ""))
        let reopened = SpeechSettings()
        precondition(reopened.resource == "seed-custom-concurr" && reopened.voice == "S_custom_voice")
        precondition(!reopened.configured && !reopened.useCloud)
        precondition(CloudSpeechCatalog.voices(for: reopened.resource).isEmpty)
        let first = CloudSpeechCatalog.voices(for: "seed-tts-1.0")
        precondition(first.count == 3 && first.first?.id == "zh_male_lanxiaoyang_mars_bigtts")
        precondition(!first.contains { $0.id == CloudSpeechCatalog.defaultVoiceID })
        precondition(CloudSpeechCatalog.initialVoice(resource: "seed-tts-1.0", saved: "my-voice", migrateDefault: true) == "my-voice")
        print("Cloud settings: migration and custom persistence PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'Verify.swift').write_text(harness)
            subprocess.run(['swiftc', '-parse-as-library', str(path / 'Verify.swift'), '-o', str(path / 'verify')], check=True)
            subprocess.run([str(path / 'verify')], check=True)


if __name__ == '__main__':
    unittest.main()
