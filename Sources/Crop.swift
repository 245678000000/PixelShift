import SwiftUI
import AppKit
import ImageIO

enum AspectChoice: String, CaseIterable, Identifiable {
    case free = "自由", original = "原始比例", square = "1:1"
    case r43 = "4:3", r34 = "3:4", r32 = "3:2", r23 = "2:3", r169 = "16:9", r916 = "9:16"
    var id: String { rawValue }

    /// width / height in pixels
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.height > 0 ? original.width / original.height : nil
        case .square: return 1
        case .r43: return 4.0 / 3
        case .r34: return 3.0 / 4
        case .r32: return 3.0 / 2
        case .r23: return 2.0 / 3
        case .r169: return 16.0 / 9
        case .r916: return 9.0 / 16
        }
    }
}

private struct DragMode {
    var left = false, right = false, top = false, bottom = false
    var move = false, new = false
    var isEdge: Bool { left || right || top || bottom }
}

private let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)

struct CropSheet: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject var item: TaskItem
    @Environment(\.dismiss) private var dismiss

    /// Normalized crop rect, origin top-left, in oriented image space.
    @State private var rect: CGRect
    @State private var preview: NSImage?
    @State private var aspect: AspectChoice = .free
    @State private var applyAll = false
    @State private var dragStart: CGRect?
    @State private var mode = DragMode()

    init(item: TaskItem) {
        self.item = item
        _rect = State(initialValue: item.crop ?? fullRect)
    }

    private var px: CGSize {
        if item.pixelSize != .zero { return item.pixelSize }
        if let p = preview { return p.size }
        return CGSize(width: 1000, height: 1000)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 470, idealHeight: 500)
        .task { preview = await loadPreview() }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let fit = fitRect(px, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 16, dy: 16))
            ZStack(alignment: .topLeading) {
                Color(white: 0.42)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Canvas { ctx, size in drawOverlay(ctx, size: size, fit: fit) }
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { handleDrag($0, fit: fit) }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }

    private func fitRect(_ s: CGSize, in box: CGRect) -> CGRect {
        guard s.width > 0, s.height > 0, box.width > 0, box.height > 0 else { return box }
        let f = min(box.width / s.width, box.height / s.height)
        let w = s.width * f, h = s.height * f
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private func viewRect(_ r: CGRect, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
               width: r.width * fit.width, height: r.height * fit.height)
    }

    private func drawOverlay(_ ctx: GraphicsContext, size: CGSize, fit: CGRect) {
        let r = viewRect(rect, fit)
        var dim = Path(fit)
        dim.addRect(r)
        ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        // rule of thirds
        var thirds = Path()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: r.minY)); thirds.addLine(to: CGPoint(x: x, y: r.maxY))
            thirds.move(to: CGPoint(x: r.minX, y: y)); thirds.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
        ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5)

        // corner + edge handles
        let L: CGFloat = min(22, r.width / 3, r.height / 3)
        var h = Path()
        for (cx, sx) in [(r.minX, 1.0), (r.maxX, -1.0)] {
            for (cy, sy) in [(r.minY, 1.0), (r.maxY, -1.0)] {
                h.move(to: CGPoint(x: cx + L * sx, y: cy)); h.addLine(to: CGPoint(x: cx, y: cy))
                h.addLine(to: CGPoint(x: cx, y: cy + L * sy))
            }
        }
        let e = L * 0.6
        h.move(to: CGPoint(x: r.midX - e, y: r.minY)); h.addLine(to: CGPoint(x: r.midX + e, y: r.minY))
        h.move(to: CGPoint(x: r.midX - e, y: r.maxY)); h.addLine(to: CGPoint(x: r.midX + e, y: r.maxY))
        h.move(to: CGPoint(x: r.minX, y: r.midY - e)); h.addLine(to: CGPoint(x: r.minX, y: r.midY + e))
        h.move(to: CGPoint(x: r.maxX, y: r.midY - e)); h.addLine(to: CGPoint(x: r.maxX, y: r.midY + e))
        ctx.stroke(h, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .square))

        // size label
        let label = Text(verbatim: "\(pxW) × \(pxH)").font(.system(size: 11, weight: .medium)).foregroundColor(.white)
        let resolved = ctx.resolve(label)
        let ts = resolved.measure(in: size)
        let pill = CGRect(x: r.midX - ts.width / 2 - 8, y: max(fit.minY, r.minY) + 8, width: ts.width + 16, height: ts.height + 6)
        if r.height > 50 && r.width > ts.width + 24 {
            ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.55)))
            ctx.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY))
        }
    }

    // MARK: Dragging

    private var minNorm: CGSize { CGSize(width: min(1, 8 / px.width), height: min(1, 8 / px.height)) }

    private func handleDrag(_ v: DragGesture.Value, fit: CGRect) {
        guard fit.width > 0, fit.height > 0 else { return }
        if dragStart == nil {
            dragStart = rect
            let r = viewRect(rect, fit), p = v.startLocation, t: CGFloat = 14
            let inY = p.y > r.minY - t && p.y < r.maxY + t
            let inX = p.x > r.minX - t && p.x < r.maxX + t
            var m = DragMode()
            m.left = abs(p.x - r.minX) < t && inY
            m.right = !m.left && abs(p.x - r.maxX) < t && inY
            m.top = abs(p.y - r.minY) < t && inX
            m.bottom = !m.top && abs(p.y - r.maxY) < t && inX
            if !m.isEdge {
                if r.contains(p) { m.move = true } else { m.new = true }
            }
            mode = m
        }
        guard let s = dragStart else { return }
        let dx = v.translation.width / fit.width, dy = v.translation.height / fit.height
        let mn = minNorm

        if mode.move {
            var r = s
            r.origin.x = clamp(s.minX + dx, 0, 1 - s.width)
            r.origin.y = clamp(s.minY + dy, 0, 1 - s.height)
            rect = r
            return
        }

        if mode.new {
            let a = CGPoint(x: clamp((v.startLocation.x - fit.minX) / fit.width, 0, 1),
                            y: clamp((v.startLocation.y - fit.minY) / fit.height, 0, 1))
            let b = CGPoint(x: clamp((v.location.x - fit.minX) / fit.width, 0, 1),
                            y: clamp((v.location.y - fit.minY) / fit.height, 0, 1))
            guard abs(b.x - a.x) > mn.width || abs(b.y - a.y) > mn.height else { return }
            var m = DragMode()
            m.left = b.x < a.x; m.right = !m.left
            m.top = b.y < a.y; m.bottom = !m.top
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: max(abs(b.x - a.x), mn.width), height: max(abs(b.y - a.y), mn.height))
            rect = enforceAspect(r.intersection(fullRect), m)
            return
        }

        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if mode.left { minX = clamp(s.minX + dx, 0, maxX - mn.width) }
        if mode.right { maxX = clamp(s.maxX + dx, minX + mn.width, 1) }
        if mode.top { minY = clamp(s.minY + dy, 0, maxY - mn.height) }
        if mode.bottom { maxY = clamp(s.maxY + dy, minY + mn.height, 1) }
        rect = enforceAspect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), mode)
    }

    /// Adjust `r` to the chosen aspect ratio, keeping the edges opposite to the dragged ones fixed.
    private func enforceAspect(_ r: CGRect, _ m: DragMode) -> CGRect {
        guard let R = aspect.ratio(original: px), px.width > 0, px.height > 0 else { return r }
        let k = px.width / (R * px.height) // hn = wn * k
        var w = r.width, h = r.height
        if m.left || m.right { h = w * k } else { w = h / k }
        // fit within bounds
        let maxW = m.left ? r.maxX : (m.right ? 1 - r.minX : 1)
        let maxH = m.top ? r.maxY : (m.bottom ? 1 - r.minY : 1)
        if w > maxW { w = maxW; h = w * k }
        if h > maxH { h = maxH; w = h / k }
        let x = m.left ? r.maxX - w : (m.right ? r.minX : clamp(r.midX - w / 2, 0, 1 - w))
        let y = m.top ? r.maxY - h : (m.bottom ? r.minY : clamp(r.midY - h / 2, 0, 1 - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func applyAspectChoice() {
        guard let R = aspect.ratio(original: px) else { return }
        let k = px.width / (R * px.height)
        var w: CGFloat = 1, h = k
        if h > 1 { h = 1; w = 1 / k }
        rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    // MARK: Controls

    private var pxW: Int { Int((rect.width * px.width).rounded()) }
    private var pxH: Int { Int((rect.height * px.height).rounded()) }

    private func pxBinding(_ get: @escaping (CGRect) -> CGFloat, axis: CGFloat,
                           set: @escaping (inout CGRect, CGFloat) -> Void) -> Binding<Int> {
        Binding(
            get: { Int((get(rect) * axis).rounded()) },
            set: { v in
                var r = rect
                set(&r, CGFloat(max(0, v)) / axis)
                r.size.width = clamp(r.width, minNorm.width, 1)
                r.size.height = clamp(r.height, minNorm.height, 1)
                r.origin.x = clamp(r.minX, 0, 1 - r.width)
                r.origin.y = clamp(r.minY, 0, 1 - r.height)
                rect = r
            })
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                field("X:", pxBinding({ $0.minX }, axis: px.width) { $0.origin.x = $1 })
                field("Y:", pxBinding({ $0.minY }, axis: px.height) { $0.origin.y = $1 })
                field("宽度:", pxBinding({ $0.width }, axis: px.width) { $0.size.width = $1 })
                field("高度:", pxBinding({ $0.height }, axis: px.height) { $0.size.height = $1 })
            }
            HStack(spacing: 14) {
                Picker("比例", selection: $aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .onChange(of: aspect) { _, _ in applyAspectChoice() }
                Toggle("应用于列表中所有文件", isOn: $applyAll).toggleStyle(.checkbox)
                Spacer()
                Button("重置") { rect = fullRect; aspect = .free }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func field(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            TextField("", value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    private func apply() {
        let isFull = rect.width > 0.9995 && rect.height > 0.9995
        let value: CGRect? = isFull ? nil : rect
        let targets = applyAll ? store.items : [item]
        for t in targets where t.crop != value && t.status != .running {
            t.crop = value
            store.reset(t)
        }
        dismiss()
    }

    private func loadPreview() async -> NSImage? {
        let url = item.url
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }.value
    }
}

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
