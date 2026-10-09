import Foundation
import Security
import Observation

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
    init() { hasSecret = (try? secret())?.isEmpty == false }
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
    func save(secret: String) -> Bool {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var code = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
            if code == errSecItemNotFound { code = SecItemAdd(keyQuery.merging(attributes) { _, new in new } as CFDictionary, nil) }
            guard code == errSecSuccess else { status = "无法安全保存密钥，请重试"; return false }
        }
        hasSecret = (try? self.secret())?.isEmpty == false
        appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        resource = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefs = UserDefaults.standard
        prefs.set(cloud, forKey: "speech.cloud"); prefs.set(legacy, forKey: "speech.legacy")
        prefs.set(appID, forKey: "speech.appID")
        prefs.set(resource, forKey: "speech.resource")
        prefs.set(voice, forKey: "speech.voice")
        status = "已保存"; return true
    }
    func clearSecret() {
        let code = SecItemDelete(keyQuery as CFDictionary)
        if code == errSecSuccess || code == errSecItemNotFound { hasSecret = false; status = "已清除云端密钥" }
        else { status = "无法清除密钥，请重试" }
    }
}
