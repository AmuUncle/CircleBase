import SwiftUI

/// CircleBase iOS 基座首期入口：只做蓝牙配对闭环 + 连接即校时。
/// 基座期仅前台运行（已拍板，不做后台保活），见 PLAN-003 §2 不做清单。
@main
struct CircleBaseApp: App {
    @StateObject private var ble = BleLink.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
    }
}
