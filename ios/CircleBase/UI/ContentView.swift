import SwiftUI
import CoreBluetooth

/// 首期单页：扫描 → 选择设备 → 连接 → 触发系统配对 → 显示"已验证"。
/// 除配对链路外零业务功能（见 PLAN-003 §3.5）。
struct ContentView: View {
    @ObservedObject var ble = BleLink.shared

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
            }
            .navigationTitle("CircleBase")
            .onAppear { ble.start() }
        }
    }
}

#Preview {
    ContentView()
}
