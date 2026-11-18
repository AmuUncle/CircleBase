import SwiftUI
import CoreBluetooth

/// 首期单页：扫描 → 选择设备 → 连接 → 触发系统配对 → 显示"已验证"。
/// 除配对链路外零业务功能（见 PLAN-003 §3.5）。
struct ContentView: View {
    @ObservedObject var ble = BleLink.shared
    @ObservedObject var xfer = ImageTransfer.shared

    var body: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    LabeledContent("状态", value: ble.state.rawValue)
                    if !ble.connectedName.isEmpty {
                        LabeledContent("设备", value: ble.connectedName)
                    }
                    if ble.verified {
                        Label("已验证 · 已校时", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    if !ble.lastError.isEmpty {
                        Text(ble.lastError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !ble.isConnected && !ble.devices.isEmpty {
                    Section("附近的圆屏") {
                        ForEach(ble.devices, id: \.identifier) { p in
                            Button {
                                ble.connect(p)
                            } label: {
                                HStack {
                                    Image(systemName: "circle.hexagongrid.fill")
                                        .foregroundStyle(.tint)
                                    Text(p.name?.isEmpty == false ? p.name! : "Circle 设备")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    if ble.verified {
                        Button("忘记此设备", role: .destructive) { ble.forgetDevice() }
                    } else {
                        Button("重新搜索") { ble.rescan() }
                    }
                }

                // 背景图（PLAN-007）：选图 → 1:1 裁剪 → 压缩上传 → 板端固化
                if ble.verified {
                    Section("外观") {
                        NavigationLink {
                            BackgroundImageView()
                        } label: {
                            HStack {
                                Label("背景图", systemImage: "photo.fill")
                                Spacer()
                                Text(bgSummary).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("HYC")
            .onAppear { ble.start() }
        }
    }

    /// 一行只读摘要：板上背图状态，取不到就写传输阶段。
    private var bgSummary: String {
        switch xfer.phase {
        case .announcing, .sending(_), .waitingAck: return "传输中…"
        case .clearing: return "移除中…"
        case .failed(_): return "上次失败"
        default: break
        }
        switch xfer.hasBackground {
        case .some(true): return "已设置"
        case .some(false): return "默认深色"
        case .none: return "未查询"
        }
    }
}

#Preview {
    ContentView()
}
