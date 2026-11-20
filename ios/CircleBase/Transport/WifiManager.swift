import Foundation
import Combine

/// Wi-Fi 配网状态机（PLAN-020，协议 §11 + §10）。
/// 解析板端 #WIFIL*（扫描列表）与 #WIFIS（状态推送），
/// 对外提供 scan / connect / forget 动作。仅 verified 连接下可用。
struct WifiAp: Identifiable, Equatable {
    let id: Int          // 板端 idx（0 起始）
    let ssid: String     // 空串 = 隐藏网络
    let rssi: Int
    let secure: Bool     // true=加密（需要密码）
}

final class WifiManager: ObservableObject {
    static let shared = WifiManager()

    enum Phase: Equatable {
        case idle            // 初始/未查询
        case scanning        // 已发 #WIFISCAN，等待 #WIFIL_END
        case listReady       // 列表就绪（可空：未发现网络）
        case connecting      // 已发 #WIFI，等 #WIFIS 状态
        case connected
        case failed(String)  // 连接失败原因
    }

    @Published private(set) var aps: [WifiAp] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText: String = "未查询"

    private var ble: BleLink { BleLink.shared }

    // MARK: - 动作（App → 板）

    /// 刷新板端连接状态（#WIFIS? 查询，进页时调用）。
    func refreshStatus() {
        guard ble.verified, ble.isConnected else { return }
        ble.sendText("#WIFIS?")
    }

    /// 发起板端真实扫描（#WIFISCAN）。结果异步经 #WIFIL 推回。
    func scan() {
        guard ble.verified, ble.isConnected, phase != .scanning else { return }
        aps = []
        phase = .scanning
        statusText = "正在扫描附近的网络…"
        ble.sendText("#WIFISCAN")
    }

    /// 连接选定网络（#WIFI,<ssid>,<pass>）。开放网络 password 传空串。
    func connect(_ ap: WifiAp, password: String) {
        guard ble.verified, ble.isConnected else { return }
        let name = ap.ssid.isEmpty ? "隐藏网络" : ap.ssid
        phase = .connecting
        statusText = "正在连接 \(name)…"
        // 协议 §10：按第一个逗号切分，pass 段允许含逗号，原样发送
        ble.sendText("#WIFI,\(ap.ssid),\(password)")
    }

    /// 忘记网络（#WIFIX）：清板端凭据并断开。
    func forget() {
        guard ble.verified, ble.isConnected else { return }
        ble.sendText("#WIFIX")
    }

    // MARK: - 板端消息（BleLink.handleMessage 路由进来的 #WIFI* 全族）

    func handleBoardMessage(_ message: String) {
        // #WIFIL_END 优先判（前缀也是 #WIFIL 家族）
        if message.hasPrefix("#WIFIL_END,") {
            let n = Int(message.dropFirst("#WIFIL_END,".count)) ?? 0
            phase = .listReady
            statusText = n == 0 ? "未发现网络" : "发现 \(n) 个网络"
            return
        }
        // #WIFIL,<idx>,<rssi>,<auth>,<ssid> —— ssid 取第 4 个逗号后的剩余
        //（板端把 SSID 放最后，SSID 内含逗号不破坏解析）
        if message.hasPrefix("#WIFIL,") {
            let body = message.dropFirst("#WIFIL,".count)
            let f = body.split(separator: ",", maxSplits: 3,
                               omittingEmptySubsequences: false)
            guard f.count == 4,
                  let idx = Int(f[0]),
                  let rssi = Int(f[1]) else { return }
            let ap = WifiAp(id: idx,
                            ssid: String(f[3]),
                            rssi: rssi,
                            secure: f[2] != "0")
            aps.append(ap)
            return
        }
        // #WIFIS,<state>,<ip|-> 主动推送 / 查询应答（§10.2/10.4）
        if message.hasPrefix("#WIFIS,") {
            let f = message.dropFirst("#WIFIS,".count)
                .split(separator: ",", maxSplits: 1,
                       omittingEmptySubsequences: false)
            guard let st = Int(f.first ?? "") else { return }
            let ip = f.count > 1 ? String(f[1]) : "-"
            switch st {
            case 0:
                phase = .idle
                statusText = "Wi-Fi 已关闭（板端开关）"
            case 1:
                // idle：连接请求发出后短暂经过属正常，不抢占 connecting 态
                if phase != .connecting { phase = .listReady }
                statusText = "未连接"
            case 2:
                phase = .connecting
                statusText = "连接中…"
            case 3:
                phase = .connected
                statusText = "已连接 · IP \(ip)"
            case 4:
                phase = .failed("连接失败：请检查密码或信号强度")
            default:
                break
            }
        }
    }
}
