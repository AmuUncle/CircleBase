import SwiftUI
import CoreBluetooth

/// 主页：扫描 → 选择设备 → 连接 → 触发系统配对 → 显示“已验证”。
/// 视图层重构：深色卡片化风格；BLE 链路与状态机仍由 BleLink / ImageTransfer 提供，本页只订阅状态与转发动作。
struct ContentView: View {
    @ObservedObject private var ble = BleLink.shared
    @ObservedObject private var xfer = ImageTransfer.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPhone.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Theme.Space.md) {
                        header
                        hero

                        if showDeviceList {
                            deviceList
                        }

                        actions

                        if ble.verified {
                            featureGrid
                        }
                    }
                    .padding(Theme.Space.md)
                }
            }
            .navigationTitle("HYC")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { ble.start() }
            .onChange(of: ble.verified) { verified in
                if verified { Haptic.notify(.success) }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.verified ? "已连接" : "HYC · 圆屏配件")
                    .font(.footnote)
                    .foregroundColor(Theme.Color.text2)
                Text(headerTitle)
                    .font(.title2.bold())
                    .foregroundColor(Theme.Color.text1)
            }
            Spacer()
            Circle()
                .fill(LinearGradient(
                    colors: [Theme.Color.accent, Theme.Color.accent2],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(Text("C").font(.system(size: 15, weight: .bold)).foregroundColor(.white))
        }
    }

    private var headerTitle: String {
        if ble.verified || !ble.connectedName.isEmpty {
            return ble.connectedName.isEmpty ? "我的设备" : ble.connectedName
        }
        return "我的设备"
    }

    // MARK: - 状态英雄卡

    @ViewBuilder
    private var hero: some View {
        switch ble.state {
        case .verified:      verifiedHero
        case .waitingPair:   pairHero
        case .scanning, .connecting: scanHero
        case .connected:     connectedHero
        default:             errorHero
        }
    }

    /// 扫描中 / 连接中：脉冲雷达 + 状态提示。
    private var scanHero: some View {
        AppCard {
            VStack(spacing: Theme.Space.sm) {
                PulseRadar {
                    Circle()
                        .fill(Theme.Color.card3)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "dot.radiowaves.left.right")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(Theme.Color.text2)
                        )
                }
                VStack(spacing: 4) {
                    Text(ble.state == .connecting ? "正在连接设备" : "正在搜索附近的圆屏")
                        .font(.headline)
                        .foregroundColor(Theme.Color.text1)
                    Text("请保持设备在身旁并开启蓝牙")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text2)
                }
                StatusBadge(ble.state == .connecting ? "连接中…" : "扫描中…",
                            color: Theme.Color.accent)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 等待配对：锁形聚焦卡。
    private var pairHero: some View {
        AppCard {
            ZStack {
                GlowBackground()
                VStack(spacing: Theme.Space.sm) {
                    PulseRadar {
                        Circle()
                            .fill(Theme.Color.accent.opacity(0.15))
                            .frame(width: 64, height: 64)
                            .overlay(
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundColor(Theme.Color.accent)
                            )
                    }
                    VStack(spacing: 4) {
                        Text("需要配对验证")
                            .font(.headline)
                            .foregroundColor(Theme.Color.text1)
                        Text("请在圆屏上查看 6 位配对码，并在 iPhone 弹窗中输入")
                            .font(.footnote)
                            .foregroundColor(Theme.Color.text2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    StatusBadge("等待配对码…", color: Theme.Color.warn)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 已连接但未验证。
    private var connectedHero: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("链路状态")
                            .font(.footnote)
                            .foregroundColor(Theme.Color.text2)
                        Text("已连接，等待认证")
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.text1)
                    }
                    Spacer()
                    StatusBadge("未验证", color: Theme.Color.warn)
                }
                Text("认证通过后会自动同步手机时间。")
                    .font(.footnote)
                    .foregroundColor(Theme.Color.text3)
            }
        }
    }

    /// 已验证：连接英雄卡 + 渐变光晕。
    private var verifiedHero: some View {
        AppCard {
            ZStack {
                GlowBackground()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("链路状态")
                                .font(.footnote)
                                .foregroundColor(Theme.Color.text2)
                            Text("已连接 · 已校时")
                                .font(.title3.bold())
                                .foregroundColor(Theme.Color.text1)
                        }
                        Spacer()
                        StatusBadge("已验证", color: Theme.Color.ok, systemImage: "checkmark.seal.fill")
                    }
                    Text("连接成功后已自动同步手机时间；断连后可在下方忘记设备。")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text3)
                }
            }
        }
    }

    /// 错误 / 断开 / 蓝牙关闭等兜底态。
    private var errorHero: some View {
        AppCard {
            VStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.Color.danger.opacity(0.12))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.Color.danger)
                    )
                VStack(spacing: 4) {
                    Text(errorTitle)
                        .font(.headline)
                        .foregroundColor(Theme.Color.text1)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text2)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                if !ble.lastError.isEmpty {
                    StatusBadge("上次失败", color: Theme.Color.danger)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var errorTitle: String {
        switch ble.state {
        case .noBLE:       return "本设备不支持蓝牙"
        case .bluetoothOff: return "蓝牙未开启"
        case .disconnected: return "连接已断开"
        default:           return "无法继续"
        }
    }

    private var errorMessage: String {
        if !ble.lastError.isEmpty { return ble.lastError }
        switch ble.state {
        case .bluetoothOff: return "请在「设置 › 蓝牙」中开启蓝牙后返回本 App"
        case .noBLE:        return "当前设备不支持蓝牙"
        case .disconnected: return "请贴近设备后重试，或忘记设备重新配对"
        default:            return "请稍后重试"
        }
    }

    // MARK: - 设备列表

    private var showDeviceList: Bool {
        !ble.isConnected && !ble.devices.isEmpty
    }

    private var deviceList: some View {
        VStack(spacing: Theme.Space.xs) {
            ForEach(ble.devices, id: \.identifier) { peripheral in
                Button {
                    Haptic.impact(.light)
                    ble.connect(peripheral)
                } label: {
                    AppRow {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.Color.card3)
                                .frame(width: 38, height: 38)
                                .overlay(
                                    Image(systemName: "circle.hexagongrid.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(Theme.Color.text2)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deviceName(peripheral))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Theme.Color.text1)
                                Text("点击连接")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.Color.text3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundColor(Theme.Color.text3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: ble.devices.count)
    }

    private func deviceName(_ peripheral: CBPeripheral) -> String {
        peripheral.name?.isEmpty == false ? peripheral.name! : "Circle 设备"
    }

    // MARK: - 操作按钮

    private var actions: some View {
        VStack(spacing: Theme.Space.xs) {
            if ble.verified {
                AppButton("忘记此设备", systemImage: "arrow.left.circle", style: .dangerGhost) {
                    Haptic.notify(.warning)
                    ble.forgetDevice()
                }
            } else {
                AppButton("重新搜索", systemImage: "arrow.clockwise", style: .ghost) {
                    ble.rescan()
                }
            }
        }
    }

    // MARK: - 功能瓦片网格（后续模块在此扩展）

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm),
                            GridItem(.flexible(), spacing: Theme.Space.sm)],
                   spacing: Theme.Space.sm) {
            NavigationLink {
                BackgroundImageView()
            } label: {
                FeatureTile(icon: "photo.fill", title: "背景图", subtitle: bgSummary, soon: false)
            }
            .buttonStyle(.plain)

            FeatureTile(icon: "plus", title: "更多功能",
                        subtitle: "后续模块以瓦片形式加入此网格", soon: true)
        }
    }

    /// 板上背图只读摘要：取不到就写传输阶段。
    private var bgSummary: String {
        switch xfer.phase {
        case .announcing, .sending(_), .waitingAck: return "传输中…"
        case .clearing: return "移除中…"
        case .failed(_): return "上次失败"
        default: break
        }
        switch xfer.hasBackground {
        case .some(true):  return "已设置 · 点击更换"
        case .some(false): return "默认深色"
        case .none:        return "未查询"
        }
    }
}

#Preview {
    NavigationStack { ContentView() }
}
