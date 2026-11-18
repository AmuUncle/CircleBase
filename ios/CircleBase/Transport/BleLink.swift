import Foundation
import CoreBluetooth

/// 连接状态（对应 BLE-PROTOCOL §3 App 侧状态表的本期子集）。
enum CircleLinkState: String {
    case noBLE       = "本设备不支持蓝牙"
    case bluetoothOff = "蓝牙未开启"
    case scanning    = "搜索设备中…"
    case connecting  = "连接中…"
    case waitingPair = "等待配对（请在 iPhone 弹窗输入圆屏上的 6 位码）"
    case connected   = "已连接，未验证"
    case verified    = "已验证"
    case disconnected = "已断开"
}

/// 圆屏 BLE 链路（首期只做配对 + 校时）。
///
/// 触发配对的唯一正路（协议 §2.1）：连接订阅 TX 后，向带 WRITE_ENC|WRITE_AUTHEN 的 RX
/// 写第一条 `#HELLO` → iOS 自动弹系统配对框 → 用户输入板显 6 位码 → 认证完成板回 `U,1`
/// → 本类置 verified，并立即发一次 `#TIME` 校时。此后每次连接认证成功都会再校一次。
final class BleLink: NSObject, ObservableObject {
    static let shared = BleLink()

    // 协议 §1：故意不复用 MotoNav 的 6e40xxxx，避免开发环境误连 MotoNav 设备。
    private let serviceUUID = CBUUID(string: "7F3A1001-2B3C-4D5E-9F0A-1B2C3D4E5F60")
    private let rxUUID      = CBUUID(string: "7F3A1002-2B3C-4D5E-9F0A-1B2C3D4E5F60")
    private let txUUID      = CBUUID(string: "7F3A1003-2B3C-4D5E-9F0A-1B2C3D4E5F60")
    private let namePrefix  = "Circle-"
    private let defaultsKey = "CircleBoundPeripheralID"

    @Published private(set) var state: CircleLinkState = .scanning
    @Published private(set) var verified = false
    @Published private(set) var devices: [CBPeripheral] = []
    @Published private(set) var connectedName = ""
    @Published private(set) var lastError = ""

    var isConnected: Bool { peripheral?.state == .connected }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var txSubscribed = false
    private var helloSent = false
    private var wantReconnect = true

    // RX 写队列（一次一片，靠 didWriteValueFor 推进）
    private var writeQueue: [Data] = []
    private var writing = false

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外意图

    /// 启动：优先用上次绑定的 identifier 直连回绑，否则扫描。
    func start() {
        guard central.state == .poweredOn else { return }
        if let uuidStr = UserDefaults.standard.string(forKey: defaultsKey),
           let uuid = UUID(uuidString: uuidStr),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(known)
        } else {
            beginScan()
        }
    }

    func rescan() {
        guard central.state == .poweredOn else { return }
        beginScan()
    }

    func connect(_ p: CBPeripheral) {
        wantReconnect = true
        peripheral = p
        p.delegate = self
        state = .connecting
        central.stopScan()
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    /// 忘记设备：清持久化 identifier 并断开，回到扫描。
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        wantReconnect = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetLink()
        beginScan()
    }

    private func beginScan() {
        devices.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func resetLink() {
        peripheral = nil
        rx = nil
        tx = nil
        txSubscribed = false
        helloSent = false
        verified = false
        writing = false
        writeQueue.removeAll()
    }

    // MARK: - 发送

    /// 文字指令以 UTF-8 写入 RX（.withResponse，触发/依赖加密）。
    private func send(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        writeQueue.append(data)
        drainWrites()
    }

    private func drainWrites() {
        guard !writing else { return }
        guard let p = peripheral, p.state == .connected, let rx = rx else { return }
        guard let next = writeQueue.first else { return }
        writing = true
        p.writeValue(next, for: rx, type: .withResponse)
    }

    /// 订阅完成 + RX 就绪后发首条 `#HELLO`（只发一次，触发系统配对）。
    private func attemptHello() {
        guard !helloSent, txSubscribed, rx != nil, let p = peripheral, p.state == .connected else { return }
        helloSent = true
        state = .waitingPair
        send("#HELLO")
    }

    /// 校时（B 类：每次认证成功发一次）。
    private func syncClock() {
        if let msg = PhoneClockSync.message() { send(msg) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            start()
        case .poweredOff:
            state = .bluetoothOff
            lastError = "请在「设置 › 蓝牙」中开启蓝牙后返回本 App"
        case .unsupported:
            state = .noBLE
        default:
            state = .scanning
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        // 已按主服务 UUID 过滤；名字非空时再校验前缀，双保险
        if !name.isEmpty && !name.hasPrefix(namePrefix) { return }
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) {
            devices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastError = ""
        connectedName = peripheral.name ?? namePrefix
        state = .connected
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription ?? "连接失败"
        if wantReconnect { start() } else { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetLink()
        state = .disconnected
        if let error = error { lastError = error.localizedDescription }
        if wantReconnect { start() }
    }
}

// MARK: - CBPeripheralDelegate

extension BleLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            lastError = error?.localizedDescription ?? "未发现服务"
            return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == rxUUID { rx = c }
            if c.uuid == txUUID, c.properties.contains(.notify) {
                tx = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        attemptHello()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == txUUID else { return }
        txSubscribed = characteristic.isNotifying
        attemptHello()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // 弹出队首，继续发下一条
        if !writeQueue.isEmpty { writeQueue.removeFirst() }
        writing = false
        if let error = error { lastError = "写入失败：\(error.localizedDescription)" }
        drainWrites()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == txUUID,
              let value = characteristic.value,
              let str = String(data: value, encoding: .utf8) else { return }
        handleMessage(str.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        connectedName = peripheral.name ?? connectedName
    }

    private func handleMessage(_ message: String) {
        // 认证完成回执（协议 §3：U,1 三轮补发，靠 verified 去重只处理首条）
        guard message == "U,1" || message.hasPrefix("U,1,") || message.hasPrefix("U,1") else { return }
        guard !verified else { return }
        verified = true
        state = .verified
        if let id = peripheral?.identifier.uuidString {
            UserDefaults.standard.set(id, forKey: defaultsKey)
        }
        syncClock()
    }
}
