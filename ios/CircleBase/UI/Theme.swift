import SwiftUI
import UIKit

/// 全局设计令牌（深色 · 卡片化风格）。
/// 颜色 / 圆角 / 间距 / 字号收敛在此一处，后续换肤或微调只改这里。
/// 落地基线：iOS 16.0，纯 SwiftUI，不依赖第三方动画库。
enum Theme {

    // MARK: - 颜色
    enum Color {
        /// 页面最外层底色（预览稿 bg-page）
        static let bgPage   = SwiftUI.Color(red: 38/255,  green: 40/255,  blue: 46/255)
        /// 机身 / 列表底色（预览稿 bg-phone）
        static let bgPhone  = SwiftUI.Color(red: 23/255,  green: 24/255,  blue: 28/255)
        /// 主卡片层
        static let card1    = SwiftUI.Color(red: 38/255,  green: 40/255,  blue: 47/255)
        /// 次级卡片 / 行背景
        static let card2    = SwiftUI.Color(red: 47/255,  green: 50/255,  blue: 58/255)
        /// 高亮层 / 图标底
        static let card3    = SwiftUI.Color(red: 56/255,  green: 59/255,  blue: 68/255)
        /// 描边
        static let stroke   = SwiftUI.Color.white.opacity(0.07)
        /// 主文字
        static let text1    = SwiftUI.Color(red: 244/255, green: 245/255, blue: 247/255)
        /// 次级文字
        static let text2    = SwiftUI.Color(red: 166/255, green: 173/255, blue: 185/255)
        /// 弱化文字
        static let text3    = SwiftUI.Color(red: 111/255, green: 118/255, blue: 130/255)
        /// 主强调色（蓝）
        static let accent   = SwiftUI.Color(red: 77/255,  green: 141/255, blue: 255/255)
        /// 光晕副色（紫）
        static let accent2  = SwiftUI.Color(red: 122/255, green: 92/255,  blue: 240/255)
        /// 成功
        static let ok       = SwiftUI.Color(red: 52/255,  green: 211/255, blue: 153/255)
        /// 警示
        static let warn     = SwiftUI.Color(red: 251/255, green: 191/255, blue: 36/255)
        /// 错误
        static let danger   = SwiftUI.Color(red: 248/255, green: 113/255, blue: 113/255)
    }

    // MARK: - 圆角
    enum Radius {
        static let lg: CGFloat  = 24
        static let md: CGFloat  = 18
        static let sm: CGFloat  = 12
        static let pill: CGFloat = 999
    }

    // MARK: - 间距
    enum Space {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }
}

// MARK: - 触觉反馈

/// 关键操作的系统触觉反馈（iOS 原生，无需动画库）。
enum Haptic {
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - 通用组件

/// 主卡片：深色中层背景 + 细描边 + 大圆角。
struct AppCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.Color.card1)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .stroke(Theme.Color.stroke, lineWidth: 1)
            )
    }
}

/// 次级行卡片。
struct AppRow<Content: View>: View {
    var padding: CGFloat = Theme.Space.sm
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.Color.card2)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.Color.stroke, lineWidth: 1)
            )
    }
}

/// 徽章胶囊。
struct StatusBadge: View {
    let text: String
    let color: SwiftUI.Color
    let systemImage: String?

    init(_ text: String, color: SwiftUI.Color, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// 按钮样式。
enum AppButtonStyle {
    case primary, ghost, dangerGhost
}

/// 按钮纯标签样式（不含 Button 行为），供普通按钮与 PhotosPicker 标签复用。
struct AppButtonLabel: View {
    let title: String
    let systemImage: String?
    let style: AppButtonStyle
    let disabled: Bool

    init(_ title: String,
         systemImage: String? = nil,
         style: AppButtonStyle = .primary,
         disabled: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.disabled = disabled
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .foregroundColor(foreground)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .opacity(disabled ? 0.45 : 1)
    }

    private var foreground: SwiftUI.Color {
        switch style {
        case .primary: return .white
        case .ghost: return Theme.Color.text1
        case .dangerGhost: return Theme.Color.danger
        }
    }

    private var background: SwiftUI.Color {
        switch style {
        case .primary: return Theme.Color.accent
        case .ghost: return Theme.Color.card3
        case .dangerGhost: return Theme.Color.card2
        }
    }

    private var border: SwiftUI.Color {
        switch style {
        case .primary: return .clear
        case .ghost: return Theme.Color.stroke
        case .dangerGhost: return Theme.Color.danger.opacity(0.25)
        }
    }
}

/// 普通按钮：包一层 Button 行为，标签复用 AppButtonLabel。
struct AppButton: View {
    let title: String
    let systemImage: String?
    let style: AppButtonStyle
    let disabled: Bool
    let action: () -> Void

    init(_ title: String,
         systemImage: String? = nil,
         style: AppButtonStyle = .primary,
         disabled: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            AppButtonLabel(title, systemImage: systemImage, style: style, disabled: disabled)
        }
        .disabled(disabled)
    }
}

/// 背景光晕（蓝紫双色模糊圆），铺在卡片内层。
struct GlowBackground: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Color.accent.opacity(0.22))
                .frame(width: 180, height: 180)
                .blur(radius: 30)
                .offset(x: 70, y: -60)
            Circle()
                .fill(Theme.Color.accent2.opacity(0.20))
                .frame(width: 180, height: 180)
                .blur(radius: 30)
                .offset(x: -70, y: 70)
        }
        .allowsHitTesting(false)
    }
}

/// 脉冲雷达环：两层错相扩散，配合中心内容。
struct PulseRadar<Content: View>: View {
    @State private var animate = false
    let core: Content

    init(@ViewBuilder core: () -> Content) {
        self.core = core()
    }

    var body: some View {
        ZStack {
            ForEach(0..<2) { index in
                Circle()
                    .stroke(Theme.Color.accent.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(animate ? 1.25 : 0.7)
                    .opacity(animate ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 2.2)
                        .delay(Double(index) * 0.7)
                        .repeatForever(autoreverses: false),
                        value: animate
                    )
            }
            core
        }
        .frame(width: 110, height: 110)
        .onAppear { animate = true }
    }
}

/// 功能瓦片：主页网格入口，后续新模块按此配置加入。
struct FeatureTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let soon: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.Color.card3)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(soon ? Theme.Color.text3 : Theme.Color.accent)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Color.text1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Color.text3)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(Theme.Space.sm)
        .background(Theme.Color.card2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.Color.stroke, lineWidth: 1)
        )
        .opacity(soon ? 0.65 : 1)
    }
}
