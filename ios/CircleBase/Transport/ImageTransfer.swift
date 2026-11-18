import Foundation
import CoreBluetooth

/// 背景图传输状态机（PLAN-007 §4.9，协议 §5.4 / §6.3.1）。
///
/// 上传纪律（固件只有"收齐 → 落盘 → 解码 → 回 K/N"一条慢路径，必须照做）：
///  1. 先 `#IMG,466,466,1` 宣告，等 `#IMG,K,...` 才切片（`#IMG,E,size|fmt` 直接失败）；
///  2. `'F'` 帧 type=1，**首片/尾片带响应、中间片无响应**——无响应才有吞吐，
///     带响应的尾片保证"最后一帧确实进了协议栈"，之后的 K/N 才是板子真的做完；
///  3. 尾片后等 `K,1,<id>`（固件写盘 + 回读 + JPEG 解码要一两秒，给 6s）；
///  4. 超时先**只重发尾片**探测（固件对已完成代次的重复尾片会再补一次 K），
///     仍无回执再**整份重发**（换 id，≤2 次）——比让用户重按一次按钮便宜得多；
///  5. 收到 `N,1,<id>` 说明板子拒收（帧头/落盘/解码任一失败）→ 整份重发。
///
/// 线程：与 BleLink 同规——只在 main 队列上被调用（CB 委托队列就是 .main）。
final class ImageTransfer: ObservableObject {
    static let shared = ImageTransfer()

    // 协议常量
    private let bulkTypeBG = 1
    private let bulkHdrSize = 15
    private let bulkMaxParts = 2048        // 固件位图上限（proto_bulk.h）
    private let boardMaxBytes = 96 * 1024  // 固件接收缓冲上限（BG_RX_MAX）

    enum Phase: Equatable {
        case idle
        case announcing                 // 已发 #IMG，等元信息回执
        case sending(Double)            // 分片发送中，进度 0...1
        case waitingAck                 // 全部片已交协议栈，等 K/N
        case clearing                   // 已发 #IMGCLR，等回执
        case done(String)               // 成功（带一句给用户看的文案）
        case failed(String)

        var busy: Bool {
            switch self {
            case .announcing, .sending(_), .waitingAck, .clearing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// 板上是否已有背图：nil = 还没问过/未知。`#IMGS?` 与传输结果都会更新它。
    @Published private(set) var hasBackground: Bool?

    private enum Op { case none, upload, clear }

    private var op: Op = .none
    private var jpeg = Data()
    private var bulkID: UInt8 = 0        // 代次 id，每次（重）发 &+1
    private var frames: [BleWrite] = []  // 本轮全部帧（尾片探测要重发最后一帧）
    private var sentCount = 0
    private var attempts = 0             // 整份重发次数
    private var watchdog: DispatchWorkItem?

    private init() {}

    var isBusy: Bool { phase.busy }

    /// 能不能开始一次新的传输（给 UI 用来禁用按钮并说明原因）。
    func readyToTransfer() -> String? {
        let ble = BleLink.shared
        if !ble.isConnected { return "圆屏未连接" }
        if !ble.verified { return "请先完成配对验证" }
        if !ble.caps.isEmpty && !ble.caps.contains("IMG") {
            return "当前固件不支持背景图（请升级固件）"
        }
        if isBusy { return "传输进行中" }
        return nil
    }

    // MARK: - 对外动作

    /// 上传 466×466 JPEG（调用方负责压缩到 ≤60KB）。
    func start(jpeg data: Data) {
        guard readyToTransfer() == nil else { return }
        guard data.count > 0, data.count <= boardMaxBytes else {
            phase = .failed("图片超过 \(boardMaxBytes / 1024)KB，请换一张或再压缩")
            return
        }
        op = .upload
        jpeg = data
        attempts = 0
        phase = .announcing
        BleLink.shared.onWriteFinished = { [weak self] w in self?.writeFinished(w) }
        BleLink.shared.sendText("#IMG,466,466,1")
        arm(3.0) { [weak self] in self?.failNow("圆屏没有应答图片头，请靠近设备后重试") }
    }

    /// 移除背图（板子删盘 + 主页回默认辉光）。
    func clear() {
        guard readyToTransfer() == nil else { return }
        op = .clear
        phase = .clearing
        BleLink.shared.sendText("#IMGCLR")
        arm(6.0) { [weak self] in self?.failNow("移除超时，请重试") }
    }

    /// 查询板上背图状态（不改 phase，只刷 hasBackground）。
    func refreshStatus() {
        guard BleLink.shared.verified, !isBusy else { return }
        BleLink.shared.sendText("#IMGS?")
    }

    /// 连接断了：进行中的传输一律作废（BleLink.resetLink 调用）。
    func linkDied() {
        cancelWatchdog()
        guard op != .none || isBusy else { return }
        op = .none
        frames.removeAll()
        if isBusy { phase = .failed("连接已断开") }
    }

    // MARK: - 固件回执分发

    func handleBoardMessage(_ m: String) {
        switch m {
        case "#IMG,K,466,466,1":
            guard op == .upload, case .announcing = phase else { return }
            cancelWatchdog()
            sendChunks()

        case let s where s.hasPrefix("#IMG,E"):
            guard op == .upload else { return }
            let why = s.hasSuffix("fmt") ? "固件不接受该图片格式" : "图片尺寸必须是 466×466"
            failNow(why)

        case let s where s.hasPrefix("K,1,"):
            guard op == .upload, currentID(s) == bulkID else { return }   // 旧代次回执：丢
            cancelWatchdog()
            finishUpload()

        case let s where s.hasPrefix("N,1,"):
            guard currentID(s) == bulkID else { return }
            cancelWatchdog()
            if op == .upload {
                retryWhole("圆屏校验未通过")
            } else {
                failNow("圆屏拒收了数据")
            }

        case "#IMGCLR,K":
            guard op == .clear else { return }
            cancelWatchdog()
            hasBackground = false
            op = .none
            phase = .done("已移除背景图，主页恢复默认")

        case "#IMGCLR,E":
            guard op == .clear else { return }
            cancelWatchdog()
            op = .none
            phase = .failed("移除失败，请重试")

        case let s where s.hasPrefix("#IMGS,"):
            // #IMGS,<0|1>,<w>,<h>
            let f = s.split(separator: ",")
            if f.count >= 2, let v = Int(f[1]) { hasBackground = (v != 0) }

        default:
            break
        }
    }

    /// 从 "K,1,<id>" / "N,1,<id>" 取代次 id。
    private func currentID(_ message: String) -> UInt8? {
        let f = message.split(separator: ",")
        guard f.count >= 3 else { return nil }
        return UInt8(f[2])
    }

    // MARK: - 分片

    private func sendChunks() {
        let chunk = BleLink.shared.maxChunkBytes()
        guard chunk > 0 else { failNow("链路未就绪"); return }
        let total = jpeg.count
        let parts = (total + chunk - 1) / chunk
        guard parts > 0, parts <= bulkMaxParts else {
            failNow("分片数超出固件上限，请压缩图片")
            return
        }

        bulkID = bulkID &+ 1
        var ws: [BleWrite] = []
        ws.reserveCapacity(parts)
        for i in 0..<parts {
            let off = i * chunk
            let len = min(chunk, total - off)
            let payload = jpeg.subdata(in: off..<(off + len))
            var f = Data(capacity: bulkHdrSize + len)
            f.append(0x46)                                   // 'F'
            f.append(UInt8(bulkTypeBG))
            f.append(bulkID)
            f.append(UInt8(parts & 0xFF)); f.append(UInt8((parts >> 8) & 0xFF))
            f.append(UInt8(i & 0xFF));     f.append(UInt8((i >> 8) & 0xFF))
            appendU32(&f, UInt32(total))
            appendU32(&f, UInt32(off))
            f.append(payload)
            // 首片与尾片带响应，中间无响应
            ws.append(BleWrite(f, withResponse: (i == 0 || i == parts - 1), tag: "bulk"))
        }

        frames = ws
        sentCount = 0
        phase = .sending(0)
        BleLink.shared.enqueue(ws)
        arm(8.0) { [weak self] in self?.stalled() }   // 兜底：写入一直卡住也要有反应
    }

    private func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }

    /// BleLink 每交出一帧回调一次（无响应=已入协议栈，带响应=已拿到 ATT 确认）。
    private func writeFinished(_ w: BleWrite) {
        guard w.tag == "bulk" else { return }        // #TIME 等文字写入不计进度
        guard op == .upload, case .sending = phase else { return }
        sentCount += 1
        let n = max(1, frames.count)
        if sentCount >= frames.count {
            phase = .waitingAck
            arm(6.0) { [weak self] in self?.stalled() }
        } else {
            phase = .sending(Double(sentCount) / Double(n))
            arm(8.0) { [weak self] in self?.stalled() }   // 有进展就续命
        }
    }

    /// 超时：先只重发尾片探测（固件对已完成代次的重复尾片会补 K），再整份重发。
    private func stalled() {
        guard op == .upload else { return }
        if case .waitingAck = phase, let last = frames.last {
            BleLink.shared.enqueue([BleWrite(last.data, withResponse: true)])
            arm(4.0) { [weak self] in self?.retryWhole("圆屏没有回传结果") }
        } else {
            retryWhole("传输中断")
        }
    }

    /// 整份重发：换 id 重切一遍——固件见到新代次会自己清掉旧的半截接收状态，不必再发 #IMG。
    private func retryWhole(_ why: String) {
        guard op == .upload else { return }
        attempts += 1
        guard attempts <= 2 else {
            failNow("\(why)：已重试 \(attempts - 1) 次仍失败，请贴近设备再试")
            return
        }
        sendChunks()
    }

    private func finishUpload() {
        op = .none
        frames.removeAll()
        sentCount = 0
        hasBackground = true
        phase = .done("背景图已设置，重启依然有效")
        BleLink.shared.onWriteFinished = nil
    }

    private func failNow(_ text: String) {
        cancelWatchdog()
        op = .none
        frames.removeAll()
        sentCount = 0
        attempts = 0
        phase = .failed(text)
        BleLink.shared.onWriteFinished = nil
    }

    // MARK: - 定时器

    /// 单一看门狗：每次有新进展就重置，过期动作由调用点决定。
    private func arm(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        cancelWatchdog()
        let item = DispatchWorkItem(block: action)
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
