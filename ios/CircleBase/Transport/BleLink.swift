import Foundation
import CoreBluetooth

/// RX 写队列里的一次写入（PLAN-007 §4.8）。
/// bulk 分片中间片走无响应（吞吐），首/尾片走带响应（拿得到错误与整份落地的节拍）。
struct BleWrite {
    let data: Data
    let withResponse: Bool
    /// 归属标记（"bulk" = 背景图分片），供传输层只统计自己排的帧。
    let tag: String?
    init(_ data: Data, withResponse: Bool = true, tag: String? = nil) {
        self.data = data
        self.withResponse = withResponse
        self.tag = tag
    }
}

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
    /// 固件能力宣告（协议 §7：`CAP,<mod>,<ver>`，认证成功后逐条下发）。
    @Published private(set) var caps: Set<String> = []

    var isConnected: Bool { peripheral?.state == .connected }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var txSubscribed = false
    private var helloSent = false
    private var wantReconnect = true

    // RX 写队列（一次一片：带响应靠 didWriteValueFor 推进，无响应靠 canSendWriteWithoutResponse）
    private var writeQueue: [BleWrite] = []
    private var writing = false
    private var retryScheduled = false
    /// 一次写入真正交给协议栈后的回调（ImageTransfer 用它算进度）。
    var onWriteFinished: ((BleWrite) -> Void)?

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
        retryScheduled = false
        caps.removeAll()
        writeQueue.removeAll()
        ImageTransfer.shared.linkDied()
    }

    // MARK: - 发送

    /// 文字指令以 UTF-8 写入 RX（.withResponse，触发/依赖加密）。
    func sendText(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        enqueue([BleWrite(data, withResponse: true)])
    }

    /// 批量入队（bulk 分片由 ImageTransfer 一次性排好，保证顺序）。
    func enqueue(_ writes: [BleWrite]) {
        writeQueue.append(contentsOf: writes)
        drainWrites()
    }

    /// 单帧可携带的净荷上限：ATT 单次写入上限再减 `'F'` 帧头 15 字节（协议 §6.3）。
    func maxChunkBytes() -> Int {
        guard let p = peripheral, p.state == .connected else { return 0 }
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        return max(0, mtu - 15)
    }

    private func drainWrites() {
        guard let p = peripheral, p.state == .connected, let rx = rx else { return }
        guard !writeQueue.isEmpty else { return }
        // 带响应写入在飞：等 didWriteValueFor 回来再继续
        if writing { return }

        while let next = writeQueue.first {
            if next.withResponse {
                writing = true
                p.writeValue(next.data, for: rx, type: .withResponse)
                return                      // 完成回调里出队并继续
            }
            // 无响应：协议栈缓冲满时 canSendWriteWithoutResponse 转 false，退避等 ready 回调
            guard p.canSendWriteWithoutResponse else { scheduleDrain(); return }
            p.writeValue(next.data, for: rx, type: .withoutResponse)
            writeQueue.removeFirst()
            onWriteFinished?(next)
        }
    }

    /// 20ms 退避重试（ready 回调正常会先到，这里只兜底某些机型不回调的情况）。
    private func scheduleDrain() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.retryScheduled = false
            self?.drainWrites()
        }
    }

    /// 订阅完成 + RX 就绪后发首条 `#HELLO`（只发一次，触发系统配对）。
    private func attemptHello() {
        guard !helloSent, txSubscribed, rx != nil, let p = peripheral, p.state == .connected else { return }
        helloSent = true
        state = .waitingPair
        sendText("#HELLO")
    }

    /// 校时（B 类：每次认证成功发一次）。
    private func syncClock() {
        if let msg = PhoneClockSync.message() { sendText(msg) }
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
        // 弹出队首（带响应写入的唯一推进点），继续发下一条
        let done = writeQueue.first
        if !writeQueue.isEmpty { writeQueue.removeFirst() }
        writing = false
        if let error = error { lastError = "写入失败：\(error.localizedDescription)" }
        if let done = done { onWriteFinished?(done) }
        drainWrites()
    }

    /// 无响应写入的缓冲腾空通知。新 SDK 已把这个委托方法改名为带参数标签的形式
    ///（旧的 `peripheralIsReadyToSendWriteWithoutResponse(_:)` 不再被协议识别）。
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
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
        if message == "U,1" || message.hasPrefix("U,1,") {
            if !verified {
                verified = true
                state = .verified
                if let id = peripheral?.identifier.uuidString {
                    UserDefaults.standard.set(id, forKey: defaultsKey)
                }
                syncClock()
            }
            return
        }
        // 能力宣告 CAP,<mod>,<ver>（协议 §7）
        if message.hasPrefix("CAP,") {
            let f = message.split(separator: ",")
            if f.count >= 2 { caps.insert(String(f[1])) }
            return
        }
        // 其余：K/N 通用回执 + #IMG* / #IMGS 背图类 → 交给 ImageTransfer 状态机
        //（本类回调固定在 main 队列（CBCentralManager queue: .main），直接同步转交保序）
        if message.hasPrefix("K,") || message.hasPrefix("N,")
            || message.hasPrefix("#IMG") {
            ImageTransfer.shared.handleBoardMessage(message)
        }
    }
}
