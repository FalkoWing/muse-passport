import SwiftUI

struct ContentView: View {
    @Bindable var companion: Companion
    @State private var editingToken = false
    @State private var confirmingClear = false
    @State private var confirmingRemoval = false
    @Bindable private var speechSettings = SpeechSettings.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(companion.status).font(.headline)
                    if companion.accessoryName != nil {
                        Toggle("桥接", isOn: $companion.bridgeEnabled)
                    }
                } header: {
                    Text("连接状态")
                } footer: {
                    if companion.accessoryName != nil {
                        Text(companion.bridgeEnabled
                             ? "保持蓝牙和手机网络开启，锁屏后仍可使用。要在官方 Muse App 里设置设备或换手机使用时，先关闭桥接。"
                             : "桥接已关闭，Passport 可以被官方 Muse App 或其他手机连接。")
                    }
                }

                Section("你的 Passport") {
                    if let name = companion.accessoryName {
                        LabeledContent("设备", value: name)
                        Button("移除设备", role: .destructive) { confirmingRemoval = true }
                    } else {
                        Button("添加设备") { companion.addAccessory() }
                    }
                }

                if let state = companion.bridgeState {
                    Section {
                        Text(state.sdkSettingsStatus)
                        Button("设置 SDK token") { editingToken = true }
                        Button("清除 token", role: .destructive) { confirmingClear = true }
                    } header: {
                        Text("SDK token")
                    } footer: {
                        Text("SDK token 用于 Muse 开发者设备授权，可在 gadgets.muse.ai 的账号设置中创建。保存或清除后 Passport 会重启，并保留已有的账号绑定。")
                    }
                    .disabled(!state.sdkSettingsSupported || state.sdkSettingsPending)
                }

                Section("语音回复") {
                    Text("默认使用本机 TTS，将 Muse 的文字回复朗读到 Passport，无需云端账号，也不会为语音合成上传回复文字。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("当前朗读来源", value: speechSettings.sourceDescription)
                    Label(companion.speechPlayer.systemVoiceAvailable ? "本机中文语音可用" : "未检测到本机中文语音", systemImage: "speaker.wave.2")
                    if !companion.speechPlayer.systemVoiceAvailable {
                        Link("下载中文语音的方法", destination: URL(string: "https://support.apple.com/zh-cn/111798")!)
                    }
                    Button(companion.speechPlayer.previewing ? "正在试听…" : "试听本机语音") {
                        companion.speechPlayer.preview(useCloud: false)
                    }.disabled(companion.speechPlayer.previewing || !companion.speechPlayer.systemVoiceAvailable)
                    NavigationLink("云端模型配置") { CloudSpeechEditor(player: companion.speechPlayer) }
                    Text("云端提供更多音色和更丰富的语气表现；需要联网，可能产生服务费用，回复文字会发送给火山引擎。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("云端未配置或未开启时使用本机 TTS；开播前失败也会回退本机。已开播后失败只停止本条，文字仍可阅读。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !companion.speechPlayer.status.isEmpty { Text(companion.speechPlayer.status) }
                    Text("朗读开关和音量在 Passport 菜单中设置。播放中短按 OK 停止，按住 OK 开始新录音。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Label("按住 OK 说话，松开发送", systemImage: "1.circle")
                    Label("短按上下键，阅读转录与回复", systemImage: "2.circle")
                    Label("长按下键，打开设备设置", systemImage: "3.circle")
                } header: {
                    Text("开始对话")
                } footer: {
                    Text("首次使用先刷入配套固件，在这里保存 SDK token，再到官方 Muse App 完成账号绑定与 Wi-Fi 初始化。日常对话使用手机网络。\n\n社区项目 · \(version)")
                }
            }
            .navigationTitle("Muse Passport")
            .sheet(isPresented: $editingToken) { TokenEditor { companion.updateSDKToken($0) } }
            .confirmationDialog("清除 SDK token？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) { companion.updateSDKToken(nil) }
            } message: {
                Text("这会移除 Passport 上的 SDK token。后续账号绑定或授权续期可能需要重新设置；已有的账号绑定会保留。")
            }
            .confirmationDialog("移除这台 Passport？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("移除", role: .destructive) { companion.removeAccessory() }
            } message: {
                Text("系统会同时删除蓝牙配对。设备上的账号绑定和 SDK token 不受影响。")
            }
        }
    }
}

private struct CloudSpeechEditor: View {
    @Bindable private var settings = SpeechSettings.shared
    @Bindable var player: SpeechPlayer
    @State private var cloud: Bool
    @State private var legacy: Bool
    @State private var appID: String
    @State private var modelChoice: String
    @State private var voiceChoice: String
    @State private var customModel: String
    @State private var customVoice: String
    @State private var secret = ""
    @Environment(\.dismiss) private var dismiss
    init(player: SpeechPlayer) {
        self.player = player
        let settings = SpeechSettings.shared
        _cloud = State(initialValue: settings.cloud)
        _legacy = State(initialValue: settings.legacy)
        _appID = State(initialValue: settings.appID)
        let initialResource = settings.resource.isEmpty ? CloudSpeechCatalog.modelID : settings.resource
        let initialVoice = settings.voice.isEmpty ? CloudSpeechCatalog.voices(for: initialResource).first?.id ?? "" : settings.voice
        _modelChoice = State(initialValue: CloudSpeechCatalog.models.contains(where: { $0.id == initialResource })
                             ? initialResource : CloudSpeechCatalog.custom)
        _voiceChoice = State(initialValue: CloudSpeechCatalog.voices(for: initialResource).contains(where: { $0.id == initialVoice })
                             ? initialVoice : CloudSpeechCatalog.custom)
        _customModel = State(initialValue: initialResource)
        _customVoice = State(initialValue: initialVoice)
    }
    private var resource: String {
        (modelChoice == CloudSpeechCatalog.custom ? customModel : modelChoice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var voice: String {
        (voiceChoice == CloudSpeechCatalog.custom ? customVoice : voiceChoice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var savedSecret: Bool { settings.hasSecret && legacy == settings.legacy }
    private var canPreview: Bool {
        cloud && (savedSecret || !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!legacy || !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !resource.isEmpty && !voice.isEmpty
    }
    private func save() -> Bool {
        let saved = settings.save(cloud: cloud, legacy: legacy, appID: appID, resource: resource, voice: voice, secret: secret)
        if saved { secret = "" }
        return saved
    }
    var body: some View {
        Form {
            Section {
                Toggle("启用云端 TTS", isOn: $cloud)
            } header: {
                Text("火山引擎／豆包")
            } footer: {
                Text(cloud ? "保存后优先使用云端；配置未完成时仍使用本机 TTS。" : "当前使用本机 TTS。开启后可配置云端模型和音色，关闭不会删除已保存配置。")
            }
            if cloud {
                Section("模型与音色") {
                    Picker("语音模型", selection: $modelChoice) {
                        ForEach(CloudSpeechCatalog.models, id: \.id) { Text($0.name).tag($0.id) }
                        Text("自定义").tag(CloudSpeechCatalog.custom)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: resource) { _, value in
                        if voiceChoice != CloudSpeechCatalog.custom
                            && !CloudSpeechCatalog.voices(for: value).contains(where: { $0.id == voiceChoice }) {
                            if let first = CloudSpeechCatalog.voices(for: value).first {
                                voiceChoice = first.id
                            } else {
                                customVoice = voiceChoice
                                voiceChoice = CloudSpeechCatalog.custom
                            }
                        }
                    }
                    if modelChoice == CloudSpeechCatalog.custom {
                        TextField("模型资源 ID", text: $customModel)
                    }
                    Picker("音色", selection: $voiceChoice) {
                        ForEach(CloudSpeechCatalog.voices(for: resource), id: \.id) { Text($0.name).tag($0.id) }
                        Text("自定义").tag(CloudSpeechCatalog.custom)
                    }
                    .pickerStyle(.menu)
                    if voiceChoice == CloudSpeechCatalog.custom {
                        TextField("音色 ID", text: $customVoice)
                    }
                    Text("请在火山控制台开通所选服务。自定义音色需与模型资源 ID 匹配，保存后可试听。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section("账号配置") {
                    Toggle("使用旧版 App ID / Access Token", isOn: $legacy)
                        .onChange(of: legacy) { _, _ in secret = "" }
                    if legacy { TextField("App ID", text: $appID) }
                    SecureField(savedSecret ? "已保存密钥，留空保持" : legacy ? "Access Token" : "API Key", text: $secret)
                    Text(legacy ? "填写旧版语音控制台的 App ID 和 Access Token。" : "填写新版语音控制台的 API Key，无需 App ID。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("清除已保存密钥", role: .destructive) { settings.clearSecret(); secret = "" }
                        .disabled(!settings.hasSecret)
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                if cloud {
                    Button(player.previewing ? "正在试听…" : "保存并试听云端语音") {
                        if save() { player.preview(useCloud: true) }
                    }.disabled(player.previewing || !canPreview)
                }
                if !player.status.isEmpty { Text(player.status) }
                if !settings.status.isEmpty { Text(settings.status) }
            } footer: {
                Text("密钥仅安全保存在手机，回复文字会发送给火山合成。未配置、未开启或开播前失败时使用本机 TTS；已开播后失败只停止，文字仍可阅读。")
            }
        }
        .navigationTitle("云端模型配置").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存") { if save() { dismiss() } } }
        }
        .onDisappear { secret = "" }
    }
}

/// The token goes straight to the device over the paired, encrypted link; it
/// is never stored or shown again here.
private struct TokenEditor: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private var valid: Bool { token.wholeMatch(of: /mgst_[A-Za-z0-9_-]{1,58}/) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("mgst_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(token.isEmpty || valid ? "通过已配对的加密蓝牙连接保存到 Passport。本应用不保存也不回显 token。"
                         : "请输入以 mgst_ 开头、最多 63 个字符的 SDK token。")
                }
            }
            .navigationTitle("设置 SDK token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存到设备") {
                        save(token)
                        token = ""
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
        .onDisappear { token = "" }
    }
}
