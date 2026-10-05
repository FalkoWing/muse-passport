import AccessorySetupKit
import Foundation
import PassportBridge
import UIKit

/// Temporary: an on-disk timeline of the acceptance run on a real phone, read
/// back with `devicectl device copy from`. Remove once acceptance has passed.
///
/// Records message types, sizes and status codes only, never a credential,
/// speech or a reply.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    /// When the kernel created this process; shows how long a background relaunch took.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }()

    private struct Upload {
        var opened: Date
        var messages = 0
        var bytes = 0
    }

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "diagnostics")
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics.log")
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private let timer: DispatchSourceTimer
    private var lastTick = Date()
    private var uploads: [UInt16: Upload] = [:]
    /// The latest OPEN still waiting for its acknowledgement to reach the device.
    private var pendingAck: (sequence: UInt16, since: Date)?

    private init() {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        timer = DispatchSource.makeTimerSource(queue: queue)
        // Timers do not fire while suspended, so a gap between ticks is a suspension.
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [unowned self] in tick(Date()) }
        timer.resume()
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code) \(error.localizedDescription)"
    }

    static func describe(_ event: ASAccessoryEvent) -> String {
        let name: String
        switch event.eventType {
        case .activated: name = "会话已激活"
        case .accessoryAdded: name = "配件已添加"
        case .accessoryRemoved: name = "配件已移除"
        case .accessoryChanged: name = "配件已变更"
        case .pickerDidPresent: name = "面板已显示"
        case .pickerDidDismiss: name = "面板已关闭"
        case .pickerSetupPairing: name = "面板开始蓝牙配对"
        case .pickerSetupFailed: name = "面板设置失败"
        default: name = "类型 \(event.eventType.rawValue)"
        }
        return "配件事件：" + (event.error.map { "\(name)，\(describe($0))" } ?? name)
    }

    func log(_ text: String) {
        let now = Date()
        queue.async { self.write(text, now) }
    }

    /// Call once, first thing at launch.
    @MainActor func launched() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // No "App 回到前台" right after this line means the system relaunched the app in the background.
        log("—— 进程启动，版本 \(version)，距内核创建进程 \(Self.milliseconds(Self.processStart, Date())) 毫秒 ——")
        for (name, text) in [(UIApplication.didEnterBackgroundNotification, "App 进入后台"),
                             (UIApplication.willEnterForegroundNotification, "App 回到前台")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [self] _ in log(text) }
        }
    }

    /// A message from the device.
    func received(_ message: BridgeMessage) {
        let now = Date()
        queue.async { self.note(message, now) }
    }

    /// A message to the device, once all of it was accepted or the write failed.
    func sent(_ type: UInt8, _ id: UInt16, _ body: Data, ok: Bool) {
        let now = Date()
        queue.async {
            let text: String
            switch type {
            case BridgeMessageType.hello:
                text = "→ HELLO"
            case BridgeMessageType.ready:
                text = "→ READY"
            case BridgeMessageType.response where body.count >= 3:
                let head = [UInt8](body.prefix(3))
                let status = Int16(bitPattern: UInt16(head[0]) | UInt16(head[1]) << 8)
                text = "→ RESPONSE id=\(id) status=\(status) 结束=\(Self.yes(head[2] != 0)) \(body.count - 3) 字节"
            default:
                text = "→ 消息 type=\(type) id=\(id) \(body.count) 字节"
            }
            self.write(ok ? text : text + "：未送达", now)
        }
    }

    /// The device confirmed or refused one packet.
    func wrote(_ packet: Data, _ error: Error?) {
        let now = Date()
        let failure = error.map(Self.describe)
        queue.async {
            let head = [UInt8](packet.prefix(4))
            guard head.count == 4 else { return }
            if let failure { return self.write("写入失败 type=\(head[0])：\(failure)", now) }
            let id = UInt16(head[2]) | UInt16(head[3]) << 8
            guard head[0] == BridgeMessageType.ack, let pending = self.pendingAck, pending.sequence == id else { return }
            self.pendingAck = nil
            self.write("→ OPEN 的确认已送达设备，距收到 \(Self.milliseconds(pending.since, now)) 毫秒", now)
        }
    }

    private func note(_ message: BridgeMessage, _ now: Date) {
        let info = (try? JSONSerialization.jsonObject(with: message.body)) as? [String: Any] ?? [:]
        switch message.type {
        case BridgeMessageType.credentials:
            let bound = !(info["access_token"] as? String ?? "").isEmpty
            let configured = info["sdk_token_configured"] as? Bool == true
            write("← 设备凭据 \(message.body.count) 字节：账号已绑定=\(Self.yes(bound))，SDK token 已设置=\(Self.yes(configured))，固件 \(info["version"] as? String ?? "?")", now)
        case BridgeMessageType.open:
            pendingAck = (message.sequence, now)
            if info["end"] as? Bool == false { uploads[message.id] = Upload(opened: now) }
            write("← OPEN id=\(message.id) \(info["verb"] as? String ?? "?") \(info["path"] as? String ?? "?")", now)
        case BridgeMessageType.data:
            guard var upload = uploads[message.id] else {
                return write("← DATA id=\(message.id) \(message.body.count) 字节，不属于进行中的请求", now)
            }
            upload.messages += 1
            upload.bytes += max(0, message.body.count - 1)
            let last = (message.body.first ?? 0) != 0
            uploads[message.id] = last ? nil : upload
            if upload.messages == 1 {
                write("← 第一段上传数据 id=\(message.id)，距 OPEN \(Self.milliseconds(upload.opened, now)) 毫秒", now)
            }
            if last {
                write(String(format: "← 上传结束 id=%d：%d 条消息，%d 字节，距 OPEN %.2f 秒",
                             Int(message.id), upload.messages, upload.bytes, now.timeIntervalSince(upload.opened)), now)
            }
        case BridgeMessageType.cancel:
            uploads[message.id] = nil
            write("← CANCEL id=\(message.id)：设备取消了请求", now)
        default:
            write("← 消息 type=\(message.type) id=\(message.id) \(message.body.count) 字节", now)
        }
    }

    private static func yes(_ value: Bool) -> String { value ? "是" : "否" }

    private static func milliseconds(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }

    private func tick(_ now: Date) {
        let gap = now.timeIntervalSince(lastTick)
        lastTick = max(lastTick, now)
        if gap > 3 { append(String(format: "（进程刚从挂起恢复，挂起约 %.0f 秒）", gap), now) }
    }

    private func write(_ text: String, _ now: Date) {
        tick(now)
        append(text, now)
    }

    private func append(_ text: String, _ now: Date) {
        let data = Data("\(clock.string(from: now)) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            // Must stay writable while the phone is locked.
            try? data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }
}
