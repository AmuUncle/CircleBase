import SwiftUI

/// Wi-Fi 配网页（PLAN-020）：板端真实扫描列表 → 选择 → 输密码 → 连接。
/// 链路与状态全在 WifiManager（协议 §10/§11），本页只订阅与转发动作。
struct WifiSetupView: View {
    @ObservedObject private var ble = BleLink.shared
    @ObservedObject private var wifi = WifiManager.shared

    @State private var selectedAp: WifiAp?       // 非 nil 弹密码 sheet
    @State private var password = ""
    @State private var showHiddenSheet = false   // 隐藏网络手动输入
    @State private var hiddenSsid = ""
    @State private var hiddenPassword = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                statusCard
                actions
                networkList
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.Color.bgPhone.ignoresSafeArea())
        .navigationTitle("Wi-Fi 配网")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { wifi.refreshStatus() }
        .sheet(item: $selectedAp) { ap in
            passwordSheet(ap)
        }
        .sheet(isPresented: $showHiddenSheet) {
            hiddenNetworkSheet
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("板端 Wi-Fi")
                            .font(.footnote)
                            .foregroundColor(Theme.Color.text2)
                        Text(wifi.statusText)
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.text1)
                    }
                    Spacer()
                    StatusBadge(badgeText, color: badgeColor, systemImage: badgeIcon)
                }
                if case .failed = wifi.phase {
                    Text("可在下方忘记网络后重新连接。")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text3)
                }
            }
        }
    }

    private var badgeText: String {
        switch wifi.phase {
        case .scanning:    return "扫描中"
        case .connecting:  return "连接中"
        case .connected:   return "已连接"
        case .failed:      return "失败"
        case .listReady:   return "就绪"
        case .idle:        return "未查询"
        }
    }

    private var badgeColor: Color {
        switch wifi.phase {
        case .scanning, .connecting: return Theme.Color.accent
        case .connected:             return Theme.Color.ok
        case .failed:                return Theme.Color.danger
        default:                     return Theme.Color.text3
        }
    }

    private var badgeIcon: String? {
        switch wifi.phase {
        case .connected:   return "checkmark.seal.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        default:           return nil
        }
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(spacing: Theme.Space.xs) {
            AppButton("扫描附近的网络", systemImage: "wifi.circle",
                      style: .primary,
                      disabled: !ble.verified || wifi.phase == .scanning) {
                Haptic.impact(.light)
                wifi.scan()
            }
            if wifi.phase == .connected {
                AppButton("忘记此网络", systemImage: "wifi.slash",
                          style: .dangerGhost) {
                    Haptic.notify(.warning)
                    wifi.forget()
                }
            }
        }
    }

    // MARK: - 网络列表

    @ViewBuilder
    private var networkList: some View {
        if wifi.phase == .scanning {
            AppCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在扫描，约需 2~3 秒…")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text2)
                    Spacer()
                }
            }
        } else if !wifi.aps.isEmpty {
            VStack(spacing: Theme.Space.xs) {
                Text("网络列表（按信号强度）")
                    .font(.footnote)
                    .foregroundColor(Theme.Color.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)

                ForEach(sortedAps) { ap in
                    Button {
                        Haptic.impact(.light)
                        password = ""
                        if ap.secure {
                            selectedAp = ap       // 加密网络：弹密码框
                        } else {
                            wifi.connect(ap, password: "")  // 开放网络直连
                        }
                    } label: {
                        apRow(ap)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sortedAps: [WifiAp] {
        wifi.aps.sorted { $0.rssi > $1.rssi }
    }

    private func apRow(_ ap: WifiAp) -> some View {
        AppRow {
            HStack(spacing: 12) {
                Image(systemName: ap.ssid.isEmpty ? "wifi.exclamationmark" : "wifi")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(rssiColor(ap.rssi))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ap.ssid.isEmpty ? "隐藏网络" : ap.ssid)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.Color.text1)
                        .lineLimit(1)
                    Text("\(ap.rssi) dBm · \(ap.secure ? "加密" : "开放")")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Color.text3)
                }
                Spacer()
                if ap.secure {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Color.text3)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(Theme.Color.text3)
            }
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-70):  return Theme.Color.text3      // 弱
        case ..<(-55):  return Theme.Color.warn       // 中
        default:        return Theme.Color.ok         // 强
        }
    }

    // MARK: - 密码输入 sheet（加密网络）

    private func passwordSheet(_ ap: WifiAp) -> some View {
        NavigationStack {
            VStack(spacing: Theme.Space.lg) {
                VStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(Theme.Color.accent)
                    Text(ap.ssid.isEmpty ? "隐藏网络" : ap.ssid)
                        .font(.title3.bold())
                        .foregroundColor(Theme.Color.text1)
                    Text("\(ap.rssi) dBm · 加密网络")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text3)
                }
                .padding(.top, Theme.Space.lg)

                SecureField("输入密码（至少 8 位）", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, Theme.Space.md)

                Spacer()

                AppButton("加入网络", systemImage: "checkmark.circle",
                          style: .primary,
                          disabled: password.count < 8) {
                    Haptic.notify(.success)
                    wifi.connect(ap, password: password)
                    selectedAp = nil
                }
                .padding(.bottom, Theme.Space.lg)
            }
            .navigationTitle("网络密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { selectedAp = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 隐藏网络手动输入 sheet

    private var hiddenNetworkSheet: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.lg) {
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(Theme.Color.accent)
                    Text("加入隐藏网络")
                        .font(.title3.bold())
                        .foregroundColor(Theme.Color.text1)
                    Text("输入网络的名称（SSID）与密码")
                        .font(.footnote)
                        .foregroundColor(Theme.Color.text3)
                }
                .padding(.top, Theme.Space.lg)

                VStack(spacing: Theme.Space.sm) {
                    TextField("网络名称（SSID）", text: $hiddenSsid)
                        .textFieldStyle(.roundedBorder)
                    SecureField("密码（开放网络留空）", text: $hiddenPassword)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, Theme.Space.md)

                Spacer()

                AppButton("加入网络", systemImage: "checkmark.circle",
                          style: .primary,
                          disabled: hiddenSsid.isEmpty ||
                                    (hiddenPassword.count < 8 && !hiddenPassword.isEmpty)) {
                    Haptic.notify(.success)
                    wifi.connect(WifiAp(id: -1, ssid: hiddenSsid,
                                        rssi: 0, secure: !hiddenPassword.isEmpty),
                                 password: hiddenPassword)
                    showHiddenSheet = false
                }
                .padding(.bottom, Theme.Space.lg)
            }
            .navigationTitle("其他网络")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showHiddenSheet = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
