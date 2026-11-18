import SwiftUI
import PhotosUI
import UIKit        /* UIImage / UIGraphicsImageRenderer：不依赖 SwiftUI 传递引入 */

/// 背景图设置页（PLAN-007 §4.10）。
///
/// 三步一条线：相册选图（PhotosPicker，系统代理，无需相册权限声明）
/// → 1:1 手动裁剪（拖动选位置、双指缩放，所见=输出）
/// → 导出 466×466 JPEG 并压到 ≤60KB，交给 ImageTransfer 走 bulk 上传。
///
/// 尺寸/比例的三重保证：裁剪视口是正方形、导出强制 466×466、
/// 固件 `#IMG` 再硬校验一次 466×466（协议 §5.4），错不了。
struct BackgroundImageView: View {
    @ObservedObject private var ble = BleLink.shared
    @ObservedObject private var xfer = ImageTransfer.shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var source: UIImage?          // 已归一化（方向/像素尺寸一致）
    @State private var scale: CGFloat = 1        // 用户缩放 k ∈ [1, 6]
    @State private var offset: CGSize = .zero    // 用户平移（pt）
    @State private var baseScale: CGFloat = 1    // 手势起点快照
    @State private var baseOffset: CGSize = .zero
    @State private var pickError = ""

    private let targetBytes = 60 * 1024          // D2：压缩目标
    private let boardMaxBytes = 96 * 1024        // 固件接收上限
    private let outSide: CGFloat = 466           // 与面板 1:1

    var body: some View {
        List {
            Section("圆屏当前状态") {
                LabeledContent("背景图", value: statusText)
                Button("重新查询") { xfer.refreshStatus() }
                    .disabled(!ble.verified || xfer.isBusy)
                Button {
                    xfer.clear()
                } label: {
                    Label("移除背景图（恢复默认）", systemImage: "paintbrush.slash")
                        .foregroundStyle(.red)
                }
                .disabled(blockReason != nil || xfer.hasBackground != true)
            }

            Section("选择并裁剪") {
                if let src = source {
                    cropView(src)
                    Text("拖动图片选择位置，双指缩放。裁框固定 1:1，输出 466×466。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    /* 先接成 String 常量：直接写三元字面量会在 Label 的
                       LocalizedStringKey / StringProtocol 两个重载之间报歧义 */
                    let title = source == nil ? "从相册选择图片" : "换一张"
                    Label(title, systemImage: "photo.on.rectangle.angled")
                }
                .disabled(xfer.isBusy)
                if !pickError.isEmpty {
                    Text(pickError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    upload()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text(xfer.isBusy ? "传输中…" : "上传到圆屏")
                    }
                }
                .disabled(source == nil || blockReason != nil)

                if let reason = blockReason, source != nil {
                    Text(reason).font(.footnote).foregroundStyle(.orange)
                }
                transferProgress
            } footer: {
                Text("60KB 目标体积下约 400 片，实测需要 5～15 秒，请保持 App 在前台并靠近设备。")
                    .font(.footnote)
            }
        }
        .navigationTitle("背景图")
        .onAppear { xfer.refreshStatus() }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            Task { @MainActor in
                pickerItem = nil
                pickError = ""
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else {
                    pickError = "读取相册图片失败，请重试"
                    return
                }
                let fixed = normalized(img)
                guard fixed.cgImage != nil else {
                    pickError = "图片解码失败，请换一张"
                    return
                }
                source = fixed
                resetTransform()
            }
        }
    }

    // MARK: - 子视图

    /// 方形裁剪视口：底图 aspect-fill 后按 k 缩放、按 t 平移，再裁成正方形。
    /// 预览用的边长与导出用的边长是同一个 cropSide()，所以“所见 = 输出”不会漂。
    @ViewBuilder private func cropView(_ src: UIImage) -> some View {
        let side = cropSide()
        Image(uiImage: src)
            .resizable()
            .scaledToFill()
            .scaleEffect(scale)
            .offset(clamped(offset, side: side))
            .frame(width: side, height: side)
            .clipped()
            .overlay(Rectangle().stroke(.white.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture(side: side))
            .simultaneousGesture(zoomGesture(side: side))
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    @ViewBuilder private var transferProgress: some View {
        switch xfer.phase {
        case .sending(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                Text("发送中 \(Int(p * 100))%").font(.footnote).foregroundStyle(.secondary)
            }
        case .announcing, .waitingAck, .clearing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(waitingText).font(.footnote).foregroundStyle(.secondary)
            }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var waitingText: String {
        switch xfer.phase {
        case .clearing: return "正在让圆屏删除背景图…"
        case .waitingAck: return "圆屏正在写盘解码，请稍候…"
        default: return "准备中…"
        }
    }

    private var statusText: String {
        guard ble.verified else { return "未验证" }
        switch xfer.hasBackground {
        case .some(true): return "已设置"
        case .some(false): return "无（默认深色）"
        case .none: return "查询中…"
        }
    }

    /// 有则给出禁用原因，nil = 可以动手。
    private var blockReason: String? {
        xfer.readyToTransfer()
    }

    // MARK: - 手势

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { v in
                offset = clamped(CGSize(width: baseOffset.width + v.translation.width,
                                        height: baseOffset.height + v.translation.height), side: side)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func zoomGesture(side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                scale = min(6, max(1, baseScale * v))
                offset = clamped(scaledOffset(baseOffset, from: baseScale, to: scale), side: side)
            }
            .onEnded { _ in baseScale = scale; baseOffset = offset }
    }

    /// 缩放时以图像中心为基准：平移量随总缩放同比放大，再钳回合法范围。
    private func scaledOffset(_ t: CGSize, from from1: CGFloat, to to1: CGFloat) -> CGSize {
        let r = to1 / from1
        return CGSize(width: t.width * r, height: t.height * r)
    }

    /// 平移钳位：裁框不得越出图像。
    private func clamped(_ t: CGSize, side: CGFloat) -> CGSize {
        guard let src = source, side > 0 else { return .zero }
        let st = displayBase(iw: src.size.width, ih: src.size.height, side: side) * scale
        let maxX = max(0, (src.size.width * st - side) / 2)
        let maxY = max(0, (src.size.height * st - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, t.width)),
                      height: min(maxY, max(-maxY, t.height)))
    }

    /// aspect-fill 基准缩放（像素→pt）。
    private func displayBase(iw: CGFloat, ih: CGFloat, side: CGFloat) -> CGFloat {
        max(side / iw, side / ih)
    }

    private func resetTransform() {
        scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
    }

    /// 裁剪视口边长（pt）：预览与导出共用，故与屏幕宽度绑死而不靠运行时布局宽。
    private func cropSide() -> CGFloat {
        min(340, UIScreen.main.bounds.width - 32)
    }

    // MARK: - 导出 + 压缩 + 上传

    private func upload() {
        guard let src = source, let cg = src.cgImage else { return }
        pickError = ""
        guard let jpeg = makeJPEG(from: cg) else {
            pickError = "图片处理失败，请换一张"
            return
        }
        if jpeg.count > boardMaxBytes {
            pickError = "图片过于复杂（压缩后仍超过 \(boardMaxBytes / 1024)KB），请换一张"
            return
        }
        xfer.start(jpeg: jpeg)
    }

    /// 方形视口 → 源图像素矩形 → 466×466 不透明位图。
    private func makeJPEG(from cg: CGImage) -> Data? {
        let vw = cropSide()                                  // 预览正方形边长（pt，与导出同一个）
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let st = displayBase(iw: iw, ih: ih, side: vw) * scale   // 像素→pt 的总缩放
        guard st > 0 else { return nil }

        let cropSidePx = vw / st                             // 视口对应的源像素边长
        var cx = iw / 2 - offset.width / st
        var cy = ih / 2 - offset.height / st
        cx = min(iw - cropSidePx / 2, max(cropSidePx / 2, cx))
        cy = min(ih - cropSidePx / 2, max(cropSidePx / 2, cy))
        let src = CGRect(x: cx - cropSidePx / 2, y: cy - cropSidePx / 2,
                         width: cropSidePx, height: cropSidePx)
        guard cropSidePx >= 1, src.minX >= 0, src.minY >= 0,
              src.maxX <= iw + 0.5, src.maxY <= ih + 0.5,
              let cropped = cg.cropping(to: src) else { return nil }

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1                                        // 输出严格 466×466 像素
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: CGSize(width: outSide, height: outSide),
                                         format: fmt).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: outSide, height: outSide))
        }
        // D2：0.92 起步，每次 −0.06，直到 ≤60KB
        var q: CGFloat = 0.92
        while q > 0.30 {
            if let d = out.jpegData(compressionQuality: q), d.count <= targetBytes { return d }
            q -= 0.06
        }
        return out.jpegData(compressionQuality: 0.3)
    }

    /// 抹掉 EXIF 方向并把像素尺寸与 size 对齐，后面的裁剪数学才干净。
    private func normalized(_ image: UIImage) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

#Preview {
    NavigationStack { BackgroundImageView() }
}
