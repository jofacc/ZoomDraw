import AppKit

final class DrawWindow: NSWindow {
    private let drawView: DrawView
    init(screen: NSScreen, onExit: @escaping () -> Void) {
        self.drawView = DrawView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.contentView = drawView
        self.setFrame(screen.frame, display: true)
        self.isReleasedWhenClosed = false
        drawView.onExit = onExit
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { drawView.keyDown(with: event) }
}

final class DrawView: NSView {
    var onExit: (() -> Void)?

    private var strokes: [Stroke] = []
    private var current: Stroke?
    private let toolState = DrawToolState()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor // 接受事件
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 鼠标事件
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = Stroke(tool: toolState.tool, color: toolState.color, width: toolState.lineWidth,
                         points: [p], start: p, end: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var c = current else { return }
        let p = convert(event.locationInWindow, from: nil)
        c.end = p
        if c.tool == .pen { c.points.append(p) }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let c = current { strokes.append(c) }
        current = nil
        needsDisplay = true
    }

    // MARK: - 键盘
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            onExit?()
            return
        default: break
        }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "z":
            if !strokes.isEmpty { strokes.removeLast() }
        case "x":
            strokes.removeAll()
            current = nil
        default:
            _ = toolState.handleKey(chars: chars)
        }
        needsDisplay = true
    }

    // MARK: - 绘制
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawToolbar(ctx: ctx)
        for s in strokes { StrokeRenderer.draw(s, in: ctx) }
        if let c = current { StrokeRenderer.draw(c, in: ctx) }
    }

    private func drawToolbar(ctx: CGContext) {
        let text = "工具: \(toolState.toolName)   笔触: \(Int(toolState.lineWidth))   1红 2黄 3绿 4蓝 5白   Z撤销 X清空 ESC退出" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 10
        let bgRect = NSRect(x: 20, y: bounds.height - size.height - pad * 2 - 20,
                            width: size.width + pad * 2 + 24, height: size.height + pad * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        let dot = NSRect(x: bgRect.minX + pad, y: bgRect.minY + (bgRect.height - 12) / 2, width: 12, height: 12)
        ctx.setFillColor(toolState.color.cgColor)
        ctx.fillEllipse(in: dot)
        text.draw(at: NSPoint(x: dot.maxX + 8, y: bgRect.minY + pad), withAttributes: attrs)
    }
}
