import AccessorySetupKit
@preconcurrency import CoreBluetooth
import Observation
import PassportBridge
import UIKit

private enum GATT {
    /// Advertised by every Muse gadget; the accessory picker matches on it.
    static let setup = CBUUID(string: "7FDD3D1C-38EA-46CF-8B46-314ECF5F240C")
    static let bridge = CBUUID(string: "4D757365-0010-4000-8000-6A6F6C6C7900")
    static let rx = CBUUID(string: "4D757365-0011-4000-8000-6A6F6C6C7900")
    static let tx = CBUUID(string: "4D757365-0012-4000-8000-6A6F6C6C7900")
}

/// Owns the accessory, the Bluetooth link and one `Bridge` per connection.
///
/// The link is always armed: a connection request to the chosen Passport stays
/// pending, so the system reconnects and wakes or relaunches the app whenever
/// the device shows up, until the user turns the bridge off.
@MainActor @Observable
final class Companion: NSObject {
    static let shared = Companion()

    private(set) var accessoryName: String?
    private(set) var linkStatus = "尚未添加设备" {
        didSet { if linkStatus != oldValue { Diagnostics.shared.log("界面状态：\(linkStatus)") } }
    }
    /// Present while a Passport is connected and bridged.
    private(set) var bridgeState: BridgeState? {
        didSet {
            if let status = bridgeState?.status, status != oldValue?.status { Diagnostics.shared.log("界面状态：\(status)") }
        }
    }
    var bridgeEnabled = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled")
            Diagnostics.shared.log("桥接开关=\(bridgeEnabled ? "开" : "关")")
            bridgeEnabled ? connect() : release()
        }
    }

    var status: String { bridgeState?.status ?? linkStatus }

    private struct Write {
        let packet: Data
        let done: CheckedContinuation<Bool, Never>?
    }

    @ObservationIgnored private let session = ASAccessorySession()
    @ObservationIgnored private let network = SystemNetwork()
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var rx: CBCharacteristic?
    @ObservationIgnored private var frames = BridgeFrames()
    @ObservationIgnored private var sequence: UInt16 = 0
    @ObservationIgnored private var writes: [Write] = []
    @ObservationIgnored private var inflight: Write?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var incoming: AsyncStream<BridgeMessage>.Continuation?
    @ObservationIgnored private var states: AsyncStream<BridgeState>.Continuation?
    /// Bumped for every Bluetooth connection, so a stale bridge cannot write.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var started = false
    /// Why the last connection was dropped, shown until one works again.
    @ObservationIgnored private var problem: String?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retrying = false

    func start() {
        guard !started else { return }
        started = true
        session.activate(on: .main) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // The central must exist at launch for state restoration, but only
        // once an accessory is authorized: before that it may talk to nothing.
        if UserDefaults.standard.bool(forKey: "hasAccessory") { makeCentral() }
    }

    // MARK: Accessory

    func addAccessory() {
        // Match on the service and the company identifier together: with
        // manufacturer data in the advertisement the picker finds nothing by
        // service alone, and the name sits in the scan response, unseen.
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = GATT.setup
        descriptor.bluetoothCompanyIdentifier = ASBluetoothCompanyIdentifier(rawValue: 0xFFFF)
        descriptor.supportedOptions = .bluetoothPairingLE
        let item = ASPickerDisplayItem(name: "Muse Passport", productImage: Self.productImage, descriptor: descriptor)
        session.showPicker(for: [item]) { error in
            if let error { Diagnostics.shared.log("配件面板返回错误：\(Diagnostics.describe(error))") }
        }
    }

    func removeAccessory() {
        guard let accessory = session.accessories.first else { return }
        session.removeAccessory(accessory) { _ in }
    }

    private static let productImage: UIImage = {
        let size = CGSize(width: 180, height: 240)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: 0.14, green: 0.09, blue: 0.22, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 28).fill()
            let symbol = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .medium))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: (size.width - (symbol?.size.width ?? 0)) / 2, y: (size.height - (symbol?.size.height ?? 0)) / 2))
        }
    }()

    private func handle(_ event: ASAccessoryEvent) {
        Diagnostics.shared.log("\(Diagnostics.describe(event))，已授权配件 \(session.accessories.count) 个")
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged, .pickerDidDismiss:
            let accessory = session.accessories.first
            accessoryName = accessory?.displayName
            UserDefaults.standard.set(accessory != nil, forKey: "hasAccessory")
            if accessory != nil, event.eventType != .accessoryAdded {
                makeCentral()
                connect()
            } else if accessory == nil {
                linkStatus = "尚未添加设备"
            }
        case .accessoryRemoved:
            accessoryName = nil
            problem = nil
            UserDefaults.standard.set(false, forKey: "hasAccessory")
            release()
            peripheral = nil
            linkStatus = "尚未添加设备"
        default:
            break
        }
    }

    // MARK: Bluetooth link

    private func makeCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "muse-passport"])
    }

    private func connect() {
        guard bridgeEnabled else {
            if accessoryName != nil { linkStatus = "桥接已关闭" }
            return
        }
        guard let central else { return }
        guard central.state == .poweredOn else {
            // With no accessory the system reports Bluetooth as off even when it is on.
            if central.state == .poweredOff, accessoryName != nil { linkStatus = "请打开手机蓝牙" }
            return
        }
        if peripheral == nil, let identifier = session.accessories.first?.bluetoothIdentifier {
            peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
            peripheral?.delegate = self
        }
        guard let peripheral else { return }
        switch peripheral.state {
        case .connected:
            if rx == nil { peripheral.discoverServices([GATT.bridge]) } else { greet(peripheral) }
            pump()
        default:
            // Never times out: the system connects whenever the device appears.
            linkStatus = problem ?? "正在等待 Passport 出现，请保持设备开机"
            if peripheral.state != .connecting { central.connect(peripheral) }
        }
    }

    /// Lets go of the device so another phone or the Muse app can have it.
    private func release() {
        endBridge()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        if accessoryName != nil, !bridgeEnabled { linkStatus = "桥接已关闭" }
    }

    private func characteristic(_ uuid: CBUUID, of peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?.first { $0.uuid == GATT.bridge }?.characteristics?.first { $0.uuid == uuid }
    }

    /// Subscribes, then starts a bridge once per connection. A relaunched
    /// process finds the subscription still active but has no bridge yet.
    private func greet(_ peripheral: CBPeripheral) {
        guard rx != nil, let tx = characteristic(GATT.tx, of: peripheral) else {
            linkStatus = "Passport 需要刷入蓝牙桥接固件"
            return
        }
        if !tx.isNotifying {
            peripheral.setNotifyValue(true, for: tx)
        } else if bridge == nil, failures == 0 {
            beginBridge()
        } else if bridge == nil, !retrying {
            // Stay connected but wait before trying again, so a link that
            // keeps failing is not hammered. The connection itself is kept:
            // a pending request must exist whenever the app may be suspended.
            retrying = true
            Task {
                try? await Task.sleep(for: .seconds(min(30, 1 << min(failures, 4))))
                retrying = false
                if bridge == nil, rx != nil, peripheral.state == .connected, bridgeEnabled { beginBridge() }
            }
        }
    }

    private func beginBridge() {
        epoch += 1
        let epoch = epoch
        let (messages, incoming) = AsyncStream<BridgeMessage>.makeStream()
        let (updates, states) = AsyncStream<BridgeState>.makeStream()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let bridge = Bridge(network: network, userAgent: "MusePassport/\(version)", send: { [weak self] type, id, body in
            await self?.write(type, id, body, epoch: epoch) ?? false
        }, onState: { states.yield($0) }, log: { Diagnostics.shared.log($0) })
        Diagnostics.shared.log("开始桥接")
        self.bridge = bridge
        self.incoming = incoming
        self.states = states
        bridgeState = BridgeState()
        // Single consumers keep device messages and state changes in order.
        Task { for await message in messages { await bridge.receive(message) } }
        Task { for await state in updates where self.epoch == epoch { self.bridgeState = state } }
        Task { _ = await write(BridgeMessageType.hello, 0, Data(), epoch: epoch) }
    }

    private func endBridge() {
        epoch += 1
        if bridge != nil { Diagnostics.shared.log("结束桥接") }
        if let bridge { Task { await bridge.stop() } }
        bridge = nil
        incoming?.finish()
        states?.finish()
        incoming = nil
        states = nil
        bridgeState = nil
        rx = nil
        frames.reset()
        let pending = writes + (inflight.map { [$0] } ?? [])
        writes = []
        inflight = nil
        pending.forEach { $0.done?.resume(returning: false) }
    }

    /// Drops the connection after a protocol failure; the pending connection
    /// request brings it straight back with fresh state.
    private func restart(_ reason: String) {
        problem = reason
        failures += 1
        linkStatus = reason
        endBridge()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    /// Saves a token to the device, or clears it when `token` is nil.
    func updateSDKToken(_ token: String?) {
        guard let bridge else { return }
        Task { await bridge.updateSDKToken(token) }
    }

    // MARK: Writes

    private func nextSequence() -> UInt16 {
        sequence &+= 1
        return sequence
    }

    private func packets(_ type: UInt8, _ id: UInt16, _ body: Data) -> [Data]? {
        guard let peripheral, rx != nil else { return nil }
        // Query the limit per message: it grows once the link has negotiated.
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        return try? BridgeFrames.packets(type: type, id: id, sequence: nextSequence(), body: body, mtu: mtu)
    }

    /// Writes one message and returns once the device has accepted all of it.
    private func write(_ type: UInt8, _ id: UInt16, _ body: Data, epoch: Int) async -> Bool {
        guard epoch == self.epoch, let packets = packets(type, id, body) else {
            Diagnostics.shared.sent(type, id, body, ok: false)
            return false
        }
        let ok: Bool = await withCheckedContinuation { done in
            for (index, packet) in packets.enumerated() {
                writes.append(Write(packet: packet, done: index == packets.count - 1 ? done : nil))
            }
            pump()
        }
        Diagnostics.shared.sent(type, id, body, ok: ok)
        return ok
    }

    private func pump() {
        guard inflight == nil, !writes.isEmpty, central?.state == .poweredOn,
              let peripheral, peripheral.state == .connected, let rx else { return }
        let next = writes.removeFirst()
        inflight = next
        peripheral.writeValue(next.packet, for: rx, type: .withResponse)
    }

    private func received(_ packet: Data) {
        do {
            guard let message = try frames.feed(packet) else { return }
            Diagnostics.shared.received(message)
            // The device waits about a second for this, so it jumps the queue.
            if let ack = packets(BridgeMessageType.ack, message.sequence, Data())?.first {
                writes.insert(Write(packet: ack, done: nil), at: 0)
                pump()
            }
            if message.type == BridgeMessageType.credentials {
                problem = nil
                failures = 0
            }
            incoming?.yield(message)
        } catch {
            Diagnostics.shared.log("帧错误：\(error)")
            restart("蓝牙数据顺序错误，正在重连…")
        }
    }
}

extension Companion: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Diagnostics.shared.log("手机蓝牙状态=\(central.state.rawValue)（5 表示已开启）")
        if central.state != .poweredOn, bridge != nil { endBridge() }
        connect()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return Diagnostics.shared.log("系统恢复蓝牙状态，但没有外设")
        }
        peripheral = restored
        restored.delegate = self
        // Only adopt cached handles here; writes wait for the powered-on callback.
        rx = characteristic(GATT.rx, of: restored)
        Diagnostics.shared.log("系统恢复蓝牙状态：外设连接状态=\(restored.state.rawValue)（2 表示已连接），写特征已缓存=\(rx != nil ? "是" : "否")")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Diagnostics.shared.log("蓝牙已连接，单包最大 \(peripheral.maximumWriteValueLength(for: .withoutResponse)) 字节")
        linkStatus = "蓝牙已连接，正在准备…"
        peripheral.discoverServices([GATT.bridge])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Diagnostics.shared.log("蓝牙连接失败：\(error.map(Diagnostics.describe) ?? "未知")")
        // An erased device has forgotten this phone. Trying again cannot
        // succeed and would keep everyone else off its only connection.
        if (error as? CBError)?.code == .peerRemovedPairingInformation {
            problem = "Passport 上的蓝牙配对已失效，请移除设备后重新添加"
            linkStatus = problem ?? linkStatus
            return
        }
        connect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Diagnostics.shared.log("蓝牙已断开：\(error.map(Diagnostics.describe) ?? "正常")")
        endBridge()
        connect()
    }
}

extension Companion: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { Diagnostics.shared.log("发现服务失败：\(Diagnostics.describe(error))") }
        guard let service = peripheral.services?.first(where: { $0.uuid == GATT.bridge }) else {
            linkStatus = "Passport 需要刷入蓝牙桥接固件"
            return
        }
        peripheral.discoverCharacteristics([GATT.rx, GATT.tx], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { Diagnostics.shared.log("发现特征失败：\(Diagnostics.describe(error))") }
        rx = characteristic(GATT.rx, of: peripheral)
        greet(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Diagnostics.shared.log("订阅设备通知：\(error.map(Diagnostics.describe) ?? "成功")")
        if error != nil { return restart("蓝牙认证失败，请重新添加设备") }
        greet(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let done = inflight
        inflight = nil
        if let done { Diagnostics.shared.wrote(done.packet, error) }
        if error != nil {
            done?.done?.resume(returning: false)
            return restart("蓝牙发送失败，正在重连…")
        }
        done?.done?.resume(returning: true)
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == GATT.tx, let value = characteristic.value else { return }
        received(value)
    }
}
