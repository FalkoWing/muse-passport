import Foundation
import Security
import Observation

enum CloudSpeechCatalog {
    static let modelID = "seed-tts-2.0"
    static let custom = "__custom__"
    static let defaultVoiceID = "ICL_uranus_zh_female_keainvsheng_tob"
    static let previousDefaultVoiceID = "zh_female_vv_uranus_bigtts"
    static let models: [(id: String, name: String)] = [
        (modelID, "豆包语音合成 2.0"),
        ("seed-tts-1.0", "豆包语音合成 1.0"),
    ]
    // Current TTS catalog: https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1
    static let voices: [(id: String, name: String)] = [
        (defaultVoiceID, "可爱女生 · 默认"),
        ("ICL_uranus_zh_female_tiaopigongzhu_tob", "调皮公主 · 女声"),
        ("zh_female_vv_uranus_bigtts", "Vivi 2.0 · 女声"),
        ("zh_female_liuchangnv_uranus_bigtts", "流畅女声 · 女声"),
        ("zh_male_ruyayichen_uranus_bigtts", "儒雅逸辰 · 男声"),
        ("zh_male_dayi_uranus_bigtts", "大壹 · 男声"),
    ]
    static func voices(for resource: String) -> [(id: String, name: String)] {
        switch resource {
        case modelID: voices
        case "seed-tts-1.0": [
            ("zh_male_lanxiaoyang_mars_bigtts", "懒音绵宝 · 男声"),
            ("zh_male_dongmanhaimian_mars_bigtts", "亮嗓萌仔 · 男声"),
            ("zh_female_tianmeitaozi_mars_bigtts", "甜美桃子 · 女声"),
        ]
        default: []
        }
    }
    static func initialVoice(resource: String, saved: String, migrateDefault: Bool) -> String {
        if resource == modelID && (saved.isEmpty || (migrateDefault && saved == previousDefaultVoiceID)) {
            return defaultVoiceID
        }
        if resource == modelID {
            switch saved {
            case "ICL_zh_female_keainvsheng_tob": return defaultVoiceID
            case "ICL_zh_female_tiaopigongzhu_tob": return "ICL_uranus_zh_female_tiaopigongzhu_tob"
            case "zh_female_santongyongns_saturn_bigtts": return "zh_female_liuchangnv_uranus_bigtts"
            case "zh_male_ruyayichen_saturn_bigtts": return "zh_male_ruyayichen_uranus_bigtts"
            case "zh_male_dayi_saturn_bigtts": return "zh_male_dayi_uranus_bigtts"
            default: break
            }
        }
        return saved
    }
}

@MainActor @Observable
final class SpeechSettings {
    static let shared = SpeechSettings()
    var cloud = UserDefaults.standard.bool(forKey: "speech.cloud")
    var legacy = UserDefaults.standard.bool(forKey: "speech.legacy")
    var appID = UserDefaults.standard.string(forKey: "speech.appID") ?? ""
    var resource = UserDefaults.standard.string(forKey: "speech.resource") ?? "seed-tts-2.0"
    var voice = UserDefaults.standard.string(forKey: "speech.voice") ?? ""
    private(set) var hasSecret = false
    private(set) var status = ""
    private let service = "io.github.falkowing.musepassport.tts"
    init() {
        let prefs = UserDefaults.standard
        let initial = CloudSpeechCatalog.initialVoice(resource: resource, saved: voice,
            migrateDefault: !prefs.bool(forKey: "speech.cartoonDefault"))
        if initial != voice { voice = initial; prefs.set(initial, forKey: "speech.voice") }
        prefs.set(true, forKey: "speech.cartoonDefault")
        hasSecret = (try? secret())?.isEmpty == false
    }
    var configured: Bool { hasSecret && !resource.isEmpty && !voice.isEmpty && (!legacy || !appID.isEmpty) }
    var useCloud: Bool { cloud && configured }
    var sourceDescription: String {
        useCloud ? "云端 TTS · 火山／豆包" : cloud ? "本机 TTS（云端配置未完成）" : "本机 TTS"
    }
    func secret() throws -> String {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &item)
        if code == errSecItemNotFound { return "" }
        guard code == errSecSuccess, let bytes = item as? Data, let value = String(data: bytes, encoding: .utf8) else {
            throw NSError(domain: "SpeechKeychain", code: Int(code))
        }
        return value
    }
    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "volcengine"]
    }
    func save(cloud: Bool, legacy: Bool, appID: String, resource: String, voice: String, secret: String) -> Bool {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacy != self.legacy && hasSecret && secret.isEmpty {
            status = "切换鉴权方式时，请填写对应密钥"; return false
        }
        if !secret.isEmpty {
            let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var code = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
            if code == errSecItemNotFound { code = SecItemAdd(keyQuery.merging(attributes) { _, new in new } as CFDictionary, nil) }
            guard code == errSecSuccess else { status = "无法安全保存密钥，请重试"; return false }
        }
        hasSecret = (try? self.secret())?.isEmpty == false
        self.cloud = cloud; self.legacy = legacy
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resource = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefs = UserDefaults.standard
        prefs.set(cloud, forKey: "speech.cloud"); prefs.set(legacy, forKey: "speech.legacy")
        prefs.set(self.appID, forKey: "speech.appID")
        prefs.set(self.resource, forKey: "speech.resource")
        prefs.set(self.voice, forKey: "speech.voice")
        status = cloud && !configured ? "已保存，云端配置未完成，仍使用本机 TTS" : "已保存"; return true
    }
    func clearSecret() {
        let code = SecItemDelete(keyQuery as CFDictionary)
        if code == errSecSuccess || code == errSecItemNotFound { hasSecret = false; status = "已清除云端密钥" }
        else { status = "无法清除密钥，请重试" }
    }
}
