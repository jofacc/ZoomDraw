import AppKit
import CoreGraphics

final class ZoomWindow: NSWindow {
    private let zoomView: ZoomView
    private let onExit: () -> Void

    init(screen: NSScreen, snapshot: CGImage, onExit: @escaping () -> Void) {
        self.onExit = onExit
        self.zoomView = ZoomView(snapshot: snapshot, screenFrame: screen.frame)

        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        self.isOpaque = true
        self.backgroundColor = .black
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.contentView = zoomView
        self.setFrame(screen.frame, display: true)
        self.isReleasedWhenClosed = false   // 我们用 ARC 管理生命周期

        zoomView.onExit = onExit
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        zoomView.keyDown(with: event)
    }
}

final class ZoomView: NSView {
    private let snapshot: CGImage
    private let screenFrame: NSRect
    private var zoom: CGFloat = 1.5
    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 8.0
    private var focusPoint: NSPoint = .zero // view 坐标系（0..bounds）
    private var paused = false

    // 暂停态画笔叠加
    private let toolState = DrawToolState()
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var drawingEnabled = true   // 在暂停状态下是否启用画笔
    private var isDrawing = false       // 当前是否正在拖拽绘制（影响光标）

    var onExit: (() -> Void)?

    init(snapshot: CGImage, screenFrame: NSRect) {
        self.snapshot = snapshot
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor

        // 初始焦点为当前鼠标位置
        let mouseScreen = NSEvent.mouseLocation
        let local = NSPoint(x: mouseScreen.x - screenFrame.origin.x,
                            y: mouseScreen.y - screenFrame.origin.y)
        self.focusPoint = local

        // 跟踪区域：覆盖整个 view，实时接收 mouseMoved
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        self.addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        if paused && drawingEnabled {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bw = CGFloat(snapshot.width)
        let bh = CGFloat(snapshot.height)
        let viewSize = bounds.size

        // 焦点在快照像素坐标（注意快照原点在左上，视图原点在左下；CGContext 已是左下）
        // 我们以视图中心为输出中心，焦点坐标在快照中
        let focusInImageX = (focusPoint.x / viewSize.width) * bw
        let focusInImageY = (focusPoint.y / viewSize.height) * bh

        // 输出尺寸 = 视图尺寸；从快照取一块区域 srcRect 拉伸到整个视图
        let srcW = bw / zoom
        let srcH = bh / zoom
        var srcX = focusInImageX - srcW / 2
        var srcY = focusInImageY - srcH / 2
        srcX = max(0, min(bw - srcW, srcX))
        srcY = max(0, min(bh - srcH, srcY))

        // CGImage cropping 用左上原点；CGImage 的坐标系：原点左上
        // snapshot 像素坐标 (x_top_down) = bh - (srcY + srcH)（因为我们的 srcY 是左下原点）
        let cropY = bh - (srcY + srcH)
        let cropRect = CGRect(x: srcX, y: cropY, width: srcW, height: srcH).integral

        if let cropped = snapshot.cropping(to: cropRect) {
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: bounds)
        }

        // 暂停 + 启用画笔时绘制笔迹
        if paused && drawingEnabled {
            for s in strokes { StrokeRenderer.draw(s, in: ctx) }
            if let c = current { StrokeRenderer.draw(c, in: ctx) }
        }

        drawHUD(ctx: ctx)
    }

    private func drawHUD(ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: 13)
        let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let labelColor = NSColor.white.withAlphaComponent(0.5)
        let dim = NSColor.white.withAlphaComponent(0.72)
        let white = NSColor.white
        let accent = NSColor.systemTeal

        let pad: CGFloat = 14
        let labelW: CGFloat = 42
        let rowH: CGFloat = 22
        let gap: CGFloat = 12
        let swatch: CGFloat = 18
        let swatchGap: CGFloat = 12

        let palette: [(NSColor, String)] = [
            (.systemRed, "1"), (.systemYellow, "2"), (.systemGreen, "3"),
            (.systemBlue, "4"), (.white, "5"),
        ]
        let shapes: [(String, String, DrawTool)] = [
            ("A", "自由", .pen), ("B", "矩形", .rect),
            ("C", "椭圆", .ellipse), ("D", "箭头", .arrow),
        ]

        func tw(_ s: String, _ f: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width
        }
        func drawText(_ s: String, _ f: NSFont, _ c: NSColor, _ p: NSPoint) {
            (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
        }
        @discardableResult
        func seg(_ s: String, _ f: NSFont, _ c: NSColor, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
            drawText(s, f, c, NSPoint(x: x, y: y))
            return x + tw(s, f)
        }
        func contrast(on color: NSColor) -> NSColor {
            guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? NSColor.black : NSColor.white
        }

        // ---- 测量各行内容宽度 ----
        var shapeW: CGFloat = 0
        for (k, n, _) in shapes { shapeW += tw(k, bold) + 6 + tw(n, font) + 22 }
        let brushW = tw("[", bold) + 6 + tw("减细", font) + 22 + tw("]", bold) + 6 + tw("加粗", font) + 22
        var actionW: CGFloat = 0
        for (k, n) in [("H", "显隐"), ("X", "清空"), ("Z", "撤销")] {
            actionW += tw(k, bold) + 6 + tw(n, font) + 22
        }
        let colorW = CGFloat(palette.count) * (swatch + swatchGap)
        let contentW = max(max(shapeW, brushW), max(actionW, colorW))
        let panelW = labelW + contentW + pad * 2

        let rows = 6
        let panelH = pad * 2 + CGFloat(rows) * rowH + gap
        let bgRect = NSRect(x: 20, y: bounds.height - panelH - 20, width: panelW, height: panelH)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        let labelX = bgRect.minX + pad
        let contentX = labelX + labelW
        func baseY(_ rowTop: CGFloat) -> CGFloat { rowTop - (rowH + 13) / 2 }

        let r0 = bgRect.maxY - pad   // 头部
        let r1 = r0 - rowH - gap     // 形状
        let r2 = r1 - rowH           // 颜色
        let r3 = r2 - rowH           // 笔触
        let r4 = r3 - rowH           // 操作
        let r5 = r4 - rowH           // 底部提示

        // ---- 头部：当前画笔状态（颜色随选择动态更新）----
        let hy = baseY(r0)
        if paused {
            if drawingEnabled {
                let dot = NSRect(x: labelX, y: hy + (13 - 12) / 2, width: 12, height: 12)
                ctx.setFillColor(toolState.color.cgColor)
                ctx.fillEllipse(in: dot)
                var x = dot.maxX + 8
                x = seg(toolState.toolShortName, bold, white, x, hy) + 10
                x = seg("·", font, labelColor, x, hy) + 10
                x = seg(toolState.colorName, bold, toolState.color, x, hy) + 10
                x = seg("·", font, labelColor, x, hy) + 10
                _ = seg("笔触 \(Int(toolState.lineWidth))", font, white, x, hy)
            } else {
                var x = seg("画笔已隐藏", font, labelColor, labelX, hy) + 10
                x = seg("·", font, labelColor, x, hy) + 10
                _ = seg("按 H 显示", font, white, x, hy)
            }
        } else {
            _ = seg("缩放 \(String(format: "%.1f", zoom))x", bold, white, labelX, hy)
        }

        // ---- 分隔线 ----
        let divY = r0 - rowH - gap / 2
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: NSPoint(x: labelX, y: divY))
        ctx.addLine(to: NSPoint(x: bgRect.maxX - pad, y: divY))
        ctx.strokePath()
        ctx.restoreGState()

        // ---- 形状行（高亮当前选中）----
        let sy = baseY(r1)
        drawText("形状", labelFont, labelColor, NSPoint(x: labelX, y: sy))
        var sx = contentX
        for (k, n, t) in shapes {
            let segW = tw(k, bold) + 6 + tw(n, font)
            if t == toolState.tool {
                let hl = NSRect(x: sx - 7, y: r1 - rowH + 3, width: segW + 14, height: rowH - 6)
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
                ctx.addPath(CGPath(roundedRect: hl, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
                sx = seg(k, bold, accent, sx, sy) + 6
                sx = seg(n, bold, white, sx, sy) + 22
            } else {
                sx = seg(k, bold, labelColor, sx, sy) + 6
                sx = seg(n, font, dim, sx, sy) + 22
            }
        }

        // ---- 颜色行（色块 + 数字，当前色加白圈）----
        let cy = baseY(r2)
        drawText("颜色", labelFont, labelColor, NSPoint(x: labelX, y: cy))
        var cx = contentX
        for (i, (col, digit)) in palette.enumerated() {
            let swTop = r2 - (rowH + swatch) / 2
            let rect = NSRect(x: cx, y: swTop, width: swatch, height: swatch)
            ctx.saveGState()
            ctx.setFillColor(col.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            if i == toolState.colorIndex {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                let ring = rect.insetBy(dx: -2, dy: -2)
                ctx.addPath(CGPath(roundedRect: ring, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.strokePath()
            }
            ctx.restoreGState()
            let dw = tw(digit, bold)
            drawText(digit, bold, contrast(on: col),
                     NSPoint(x: cx + (swatch - dw) / 2, y: swTop + (swatch - 13) / 2))
            cx += swatch + swatchGap
        }

        // ---- 笔触行 ----
        let by = baseY(r3)
        drawText("笔触", labelFont, labelColor, NSPoint(x: labelX, y: by))
        var bx = contentX
        bx = seg("[", bold, labelColor, bx, by) + 6
        bx = seg("减细", font, dim, bx, by) + 22
        bx = seg("]", bold, labelColor, bx, by) + 6
        _ = seg("加粗", font, dim, bx, by)

        // ---- 操作行 ----
        let ay = baseY(r4)
        drawText("操作", labelFont, labelColor, NSPoint(x: labelX, y: ay))
        var ax = contentX
        ax = seg("H", bold, labelColor, ax, ay) + 6
        ax = seg("显隐", font, dim, ax, ay) + 22
        ax = seg("X", bold, labelColor, ax, ay) + 6
        ax = seg("清空", font, dim, ax, ay) + 22
        ax = seg("Z", bold, labelColor, ax, ay) + 6
        _ = seg("撤销", font, dim, ax, ay)

        // ---- 底部提示 ----
        let fy = baseY(r5)
        let foot = paused ? "单击继续 · ESC 退出" : "滚轮 / +/- 调节 · 单击暂停绘制 · ESC 退出"
        drawText(foot, font, labelColor, NSPoint(x: labelX, y: fy))
    }

    // MARK: - 鼠标
    override func mouseMoved(with event: NSEvent) {
        if paused {
            return  // 暂停状态下不再跟随焦点
        }
        let p = convert(event.locationInWindow, from: nil)
        focusPoint = p
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !paused {
            // 单击暂停
            paused = true
            isDrawing = false
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        // 暂停状态：开始绘制
        if drawingEnabled {
            current = Stroke(tool: toolState.tool,
                             color: toolState.color,
                             width: toolState.lineWidth,
                             points: [p],
                             start: p, end: p)
            isDrawing = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard paused, drawingEnabled, var c = current else { return }
        let p = convert(event.locationInWindow, from: nil)
        c.end = p
        if c.tool == .pen { c.points.append(p) }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard paused, drawingEnabled else { return }
        if let c = current { strokes.append(c) }
        current = nil
        isDrawing = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if paused { return }
        let delta = event.scrollingDeltaY
        let factor: CGFloat = 1.0 + (delta > 0 ? 0.08 : -0.08)
        zoom = max(minZoom, min(maxZoom, zoom * factor))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            onExit?()
            return
        case 24, 69: // = / +
            if !paused { zoom = min(maxZoom, zoom + 0.5); needsDisplay = true }
            return
        case 27, 78: // - / numpad-
            if !paused { zoom = max(minZoom, zoom - 0.5); needsDisplay = true }
            return
        default: break
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        // 暂停态专属键
        if paused {
            switch chars {
            case "h", "\t":
                drawingEnabled.toggle()
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            case "x":
                strokes.removeAll()
                current = nil
                needsDisplay = true
                return
            case "z":
                if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true }
                return
            default: break
            }
            // 工具/颜色/笔触切换
            if drawingEnabled, toolState.handleKey(chars: chars) {
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }
}
