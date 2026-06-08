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
    private var zoom: CGFloat = 2.0
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
        let stateText: String
        if paused {
            stateText = drawingEnabled
                ? "已暂停 · 画笔: \(toolState.toolName) 笔触\(Int(toolState.lineWidth)) · H 隐藏画笔 · C 清空 · 点击继续"
                : "已暂停 · 画笔已隐藏(H 显示) · 点击继续 · ESC 退出"
        } else {
            stateText = "缩放 \(String(format: "%.1f", zoom))x · 鼠标移动跟随焦点 · 滚轮调节 · 左键单击暂停 · ESC 退出"
        }
        let text = stateText as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 10
        let bgRect = NSRect(x: 20, y: bounds.height - size.height - pad * 2 - 20,
                            width: size.width + pad * 2 + (paused && drawingEnabled ? 24 : 0),
                            height: size.height + pad * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path); ctx.fillPath()

        var textX = bgRect.minX + pad
        if paused && drawingEnabled {
            // 当前颜色指示点
            let dot = NSRect(x: bgRect.minX + pad, y: bgRect.minY + (bgRect.height - 12) / 2, width: 12, height: 12)
            ctx.setFillColor(toolState.color.cgColor)
            ctx.fillEllipse(in: dot)
            textX = dot.maxX + 8
        }

        NSGraphicsContext.saveGraphicsState()
        text.draw(at: NSPoint(x: textX, y: bgRect.minY + pad), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
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
            case "c":
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
