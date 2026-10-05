import SwiftUI

struct ContentView: View {
    @Bindable var companion: Companion
    @State private var editingToken = false
    @State private var confirmingClear = false
    @State private var confirmingRemoval = false

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
