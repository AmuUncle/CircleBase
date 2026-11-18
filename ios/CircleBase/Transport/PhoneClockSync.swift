import Foundation

/// 校时消息生成（BLE-PROTOCOL §5.2 / §8 `tz`）。
///
/// 偏移单位 = **分钟**（值域 -720...840），与协议文档一致；
/// 参考实现 New-MotoNav 的 PhoneClockSync 发的是「秒」，本 App 从源头统一到分钟，
/// 避免秒/分二义。B 类事件型：每次连接认证成功只发一次，绝不缓存/重放墙上时间。
enum PhoneClockSync {
    /// 生成 `#TIME,<utc秒>,<tzOffset分钟>`；时间或偏移非法时返回 nil（宁可不发也不发错）。
    static func message(wall: Date = Date(),
                        offsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60) -> String? {
        let utc = Int64(wall.timeIntervalSince1970.rounded(.down))
        // 合法域：2020-01-01 秒 ~ 2100-01-01 秒
        guard utc >= 1_577_836_800, utc < 4_102_444_800,
              (-720...840).contains(offsetMinutes) else { return nil }
        return "#TIME,\(utc),\(offsetMinutes)"
    }
}
