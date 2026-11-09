import AppKit
import CoreGraphics

final class ScreenshotWindow: NSWindow {
    let shotView: ScreenshotView

    init(screen: NSScreen, snapshot: CGImage,
         onFinish: @escaping (NSImage?, ScreenshotFinish) -> Void) {
        self.shotView = ScreenshotView(snapshot: snapshot, screen: screen)

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
        self.contentView = shotView
        self.setFrame(screen.frame, display: true)
        self.isReleasedWhenClosed = false
        shotView.onFinish = onFinish
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        // 文字输入中由 NSTextView 自行处理
        if firstResponder is NSTextView {
            super.keyDown(with: event)
        } else {
            shotView.keyDown(with: event)
        }
    }
}

enum ScreenshotFinish {
    case copied      // 复制到剪贴板
    case saved       // 已保存文件
    case record      // 转入录屏
    case cancelled
}

/// 截图选区 + 标注视图（交互参考微信 / 企业微信）
final class ScreenshotView: NSView {

    // MARK: - 状态
    private enum Phase { case picking, selected }
    private enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private enum Drag {
        case none
        case creating(origin: NSPoint)
        case moving(offset: NSSize)
        case resizing(Handle, anchor: NSRect)
        case annotating
    }

    private let snapshot: CGImage
    private let screen: NSScreen
    private let screenFrame: NSRect
    private let scale: CGFloat          // 快照像素 / view 点
    private lazy var snapshotRep = NSBitmapImageRep(cgImage: snapshot)

    private var phase: Phase = .picking
    private var drag: Drag = .none
    private var selection: NSRect = .zero
    private var mousePoint: NSPoint = .zero

    // 窗口自动识别
    private var windowRects: [NSRect] = []
    private var highlightRect: NSRect?

    // 标注
    private let toolState = DrawToolState()
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var annotating = false      // 是否已选择标注工具
    private var textEditor: ScreenshotTextView?

    private lazy var toolbar: ScreenshotToolbar = {
        let t = ScreenshotToolbar(frame: .zero)
        t.isHidden = true
        t.onAction = { [weak self] a in self?.handleToolbar(a) }
        t.onColorPick = { [weak self] i in
            guard let self = self else { return }
            self.toolState.setColorIndex(i)
            self.toolbar.colorIndex = i
            self.applyEditorStyle()
        }
        t.onWidthPick = { [weak self] w in
            guard let self = self else { return }
            self.toolState.lineWidth = w
            self.toolbar.lineWidth = w
            self.applyEditorStyle()
        }
        return t
    }()

    var onFinish: ((NSImage?, ScreenshotFinish) -> Void)?

    /// 当前选区（该屏幕的本地坐标，左下原点）
    var selectionRect: NSRect { selection.integral }
    /// 是否已确认选区
    var hasSelection: Bool { phase == .selected && !selection.isEmpty }

    // MARK: - 初始化
    init(snapshot: CGImage, screen: NSScreen) {
        self.snapshot = snapshot
        self.screen = screen
        self.screenFrame = screen.frame
        self.scale = CGFloat(snapshot.width) / screen.frame.width
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        toolState.lineWidth = 4
        addSubview(toolbar)

        let mouse = NSEvent.mouseLocation
        mousePoint = NSPoint(x: mouse.x - screenFrame.minX, y: mouse.y - screenFrame.minY)

        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // 全局坐标 → 本地坐标
        windowRects = ScreenCapture.visibleWindowRects(on: screen)
            .map { NSRect(x: $0.minX - screenFrame.minX, y: $0.minY - screenFrame.minY,
                          width: $0.width, height: $0.height) }
        updateHighlight()
        needsDisplay = true
    }

    // MARK: - 绘制
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.interpolationQuality = .high
        ctx.draw(snapshot, in: bounds)

        let sel = effectiveSelection
        // 遮罩
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        if sel.isEmpty {
            ctx.fill(bounds)
        } else {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(sel)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()

        if !sel.isEmpty {
            // 选区内的标注
            ctx.saveGState()
            ctx.clip(to: sel)
            drawAnnotations(in: ctx)
            ctx.restoreGState()

            // 边框
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: -0.75, dy: -0.75))

            if phase == .selected { drawHandles(sel, ctx: ctx) }
            drawSizeBadge(sel, ctx: ctx)
        }

        if phase == .picking {
            drawMagnifier(ctx: ctx)
            if selection.isEmpty && highlightRect == nil { drawHint(ctx: ctx) }
        }
    }

    private func drawAnnotations(in ctx: CGContext) {
        for s in strokes { drawStroke(s, ctx: ctx) }
        if let c = current { drawStroke(c, ctx: ctx) }
    }

    private func drawStroke(_ s: Stroke, ctx: CGContext) {
        if s.tool == .mosaic {
            drawMosaic(s, ctx: ctx)
        } else {
            StrokeRenderer.draw(s, in: ctx)
        }
    }

    /// 马赛克：沿路径取原图像素块打码
    private func drawMosaic(_ s: Stroke, ctx: CGContext) {
        let block = max(8, s.width * 2.5)
        var covered = Set<String>()
        ctx.saveGState()
        for p in s.points {
            let gx = (p.x / block).rounded(.down)
            let gy = (p.y / block).rounded(.down)
            let key = "\(Int(gx)),\(Int(gy))"
            if covered.contains(key) { continue }
            covered.insert(key)
            let cell = NSRect(x: gx * block, y: gy * block, width: block, height: block)
            if let color = averageColor(in: cell) {
                ctx.setFillColor(color.cgColor)
                ctx.fill(cell)
            }
        }
        ctx.restoreGState()
    }

    private func averageColor(in rect: NSRect) -> NSColor? {
        // 取矩形中心对应的快照像素（rep 为左上原点）
        let x = Int((rect.midX * scale).rounded(.down))
        let y = Int(((bounds.height - rect.midY) * scale).rounded(.down))
        guard x >= 0, y >= 0, x < snapshot.width, y < snapshot.height else { return nil }
        return snapshotRep.colorAt(x: x, y: y)
    }

    private func drawHandles(_ r: NSRect, ctx: CGContext) {
        for h in Handle.allCases {
            let p = handlePoint(h, in: r)
            let box = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: box)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: box)
        }
    }

    private func drawSizeBadge(_ r: NSRect, ctx: CGContext) {
        let text = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let tipAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let tip = (phase == .selected && !annotating) ? "  双击完成" as NSString : "" as NSString

        let size = text.size(withAttributes: attrs)
        let tipSize = tip.length > 0 ? tip.size(withAttributes: tipAttrs) : .zero
        var bg = NSRect(x: r.minX, y: r.maxY + 8,
                        width: size.width + tipSize.width + 16, height: size.height + 8)
        if bg.maxY > bounds.maxY - 4 { bg.origin.y = r.maxY - bg.height - 8 }
        if bg.maxX > bounds.maxX { bg.origin.x = bounds.maxX - bg.width - 4 }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        text.draw(at: NSPoint(x: bg.minX + 8, y: bg.minY + 4), withAttributes: attrs)
        if tip.length > 0 {
            tip.draw(at: NSPoint(x: bg.minX + 8 + size.width, y: bg.minY + 5), withAttributes: tipAttrs)
        }
    }

    private func drawHint(ctx: CGContext) {
        let text = "拖动选择区域  ·  单击选中窗口  ·  双击确认并复制  ·  ESC 退出" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let bg = NSRect(x: (bounds.width - size.width) / 2 - 16,
                        y: bounds.height * 0.5 - 20,
                        width: size.width + 32, height: size.height + 16)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        text.draw(at: NSPoint(x: bg.minX + 16, y: bg.minY + 8), withAttributes: attrs)
    }

    /// 放大镜 + 坐标 + 取色（选区阶段）
    private func drawMagnifier(ctx: CGContext) {
        let side: CGFloat = 120
        let zoom: CGFloat = 6
        let infoH: CGFloat = 34
        var origin = NSPoint(x: mousePoint.x + 18, y: mousePoint.y - side - infoH - 18)
        if origin.x + side > bounds.maxX { origin.x = mousePoint.x - side - 18 }
        if origin.y < bounds.minY { origin.y = mousePoint.y + 18 }

        let box = NSRect(x: origin.x, y: origin.y + infoH, width: side, height: side)
        let srcSide = side / zoom
        let src = CGRect(x: (mousePoint.x - srcSide / 2) * scale,
                         y: (bounds.height - mousePoint.y - srcSide / 2) * scale,
                         width: srcSide * scale, height: srcSide * scale).integral

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(box)
        if let crop = snapshot.cropping(to: src) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: box)
        }
        // 十字线
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: NSPoint(x: box.minX, y: box.midY)); ctx.addLine(to: NSPoint(x: box.maxX, y: box.midY))
        ctx.move(to: NSPoint(x: box.midX, y: box.minY)); ctx.addLine(to: NSPoint(x: box.midX, y: box.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()

        // 信息条
        let info = NSRect(x: origin.x, y: origin.y, width: side, height: infoH)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(CGPath(roundedRect: info, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()

        let pick = averageColor(in: NSRect(x: mousePoint.x, y: mousePoint.y, width: 1, height: 1))
        let hex = pick.map(Self.hexString) ?? "--"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        ("\(Int(mousePoint.x)), \(Int(bounds.height - mousePoint.y))" as NSString)
            .draw(at: NSPoint(x: info.minX + 8, y: info.minY + 18), withAttributes: attrs)

        if let c = pick {
            let sw = NSRect(x: info.minX + 8, y: info.minY + 4, width: 10, height: 10)
            ctx.setFillColor(c.cgColor)
            ctx.fill(sw)
            (hex as NSString).draw(at: NSPoint(x: sw.maxX + 6, y: info.minY + 3), withAttributes: attrs)
        }
    }

    private static func hexString(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "--" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    // MARK: - 选区计算
    private var effectiveSelection: NSRect {
        if !selection.isEmpty { return selection }
        if phase == .picking, let h = highlightRect { return h }
        return .zero
    }

    private func handlePoint(_ h: Handle, in r: NSRect) -> NSPoint {
        switch h {
        case .topLeft:     return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.midX, y: r.maxY)
        case .topRight:    return NSPoint(x: r.maxX, y: r.maxY)
        case .right:       return NSPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return NSPoint(x: r.maxX, y: r.minY)
        case .bottom:      return NSPoint(x: r.midX, y: r.minY)
        case .bottomLeft:  return NSPoint(x: r.minX, y: r.minY)
        case .left:        return NSPoint(x: r.minX, y: r.midY)
        }
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard phase == .selected, !selection.isEmpty else { return nil }
        for h in Handle.allCases {
            if NSRect(x: handlePoint(h, in: selection).x - 7,
                      y: handlePoint(h, in: selection).y - 7,
                      width: 14, height: 14).contains(p) { return h }
        }
        return nil
    }

    private func updateHighlight() {
        guard phase == .picking, selection.isEmpty else { return }
        // windowRects 已按 z-order 从前到后排列：取第一个命中的窗口即为肉眼可见的那一个
        let hit = windowRects.first { $0.contains(mousePoint) }
        if highlightRect != hit { highlightRect = hit; needsDisplay = true }
    }

    private func resize(_ h: Handle, from anchor: NSRect, to p: NSPoint) -> NSRect {
        var minX = anchor.minX, maxX = anchor.maxX, minY = anchor.minY, maxY = anchor.maxY
        switch h {
        case .topLeft:     minX = p.x; maxY = p.y
        case .top:         maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom:      minY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .left:        minX = p.x
        }
        let r = NSRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY))
        return r.intersection(bounds)
    }

    // MARK: - 鼠标
    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        updateHighlight()
        updateCursor()
        if phase == .picking { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditor()
        if window?.isKeyWindow == false { window?.makeKeyAndOrderFront(nil) }
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p

        // 双击选区内部 = 直接完成并复制（与微信一致）
        if event.clickCount >= 2, phase == .selected, selection.contains(p), !blocksDoubleClickFinish {
            drag = .none
            current = nil
            onFinish?(renderResult(), .copied)
            return
        }

        if phase == .picking {
            drag = .creating(origin: p)
            selection = NSRect(origin: p, size: .zero)
            return
        }

        // 已确定选区：控制点优先，保证随时可微调选区
        if let h = handle(at: p) {
            drag = .resizing(h, anchor: selection)
            return
        }

        if annotating && selection.contains(p) {
            if toolState.tool == .text {
                beginTextEditing(at: p)
                return
            }
            current = Stroke(tool: toolState.tool, color: toolState.color,
                             width: toolState.lineWidth, points: [p], start: p, end: p)
            drag = .annotating
            needsDisplay = true
            return
        }

        if selection.contains(p) {
            drag = .moving(offset: NSSize(width: p.x - selection.minX, height: p.y - selection.minY))
            return
        }
        // 点击选区外：重新框选
        strokes.removeAll()
        annotating = false
        toolbar.activeTool = nil
        toolbar.isHidden = true
        phase = .picking
        selection = NSRect(origin: p, size: .zero)
        drag = .creating(origin: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        switch drag {
        case .creating(let origin):
            selection = NSRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                               width: abs(p.x - origin.x), height: abs(p.y - origin.y)).intersection(bounds)
            // 明确拖拽后才放弃窗口吸附
            if hypot(p.x - origin.x, p.y - origin.y) >= 5 { highlightRect = nil }
        case .moving(let off):
            var r = selection
            r.origin = NSPoint(x: p.x - off.width, y: p.y - off.height)
            r.origin.x = max(0, min(bounds.width - r.width, r.origin.x))
            r.origin.y = max(0, min(bounds.height - r.height, r.origin.y))
            selection = r
            layoutToolbar()
        case .resizing(let h, let anchor):
            selection = resize(h, from: anchor, to: p)
            layoutToolbar()
        case .annotating:
            guard var c = current else { return }
            c.end = p
            if c.tool == .pen || c.tool == .mosaic { c.points.append(p) }
            current = c
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .creating(let origin):
            let dist = hypot(p.x - origin.x, p.y - origin.y)
            if dist < 5 {
                // 单击 → 选中高亮窗口，否则全屏
                selection = highlightRect ?? bounds
            }
            if selection.width < 3 || selection.height < 3 { selection = bounds }
            phase = .selected
            highlightRect = nil
            showToolbar()
        case .annotating:
            if let c = current, isMeaningful(c) { strokes.append(c) }
            current = nil
            toolbar.canUndo = !strokes.isEmpty
        default:
            break
        }
        drag = .none
        updateCursor()
        needsDisplay = true
    }

    private func isMeaningful(_ s: Stroke) -> Bool {
        switch s.tool {
        case .pen, .mosaic: return s.points.count > 1
        case .text: return !s.text.isEmpty
        default: return hypot(s.end.x - s.start.x, s.end.y - s.start.y) > 3
        }
    }

    /// 文字工具依赖连续点击定位输入框，此时不响应双击完成
    private var blocksDoubleClickFinish: Bool {
        annotating && toolState.tool == .text
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键：有选区则退回框选，否则退出（与微信一致）
        commitTextEditor()
        if phase == .selected {
            phase = .picking
            selection = .zero
            strokes.removeAll()
            current = nil
            annotating = false
            toolbar.isHidden = true
            toolbar.activeTool = nil
            updateHighlight()
            needsDisplay = true
        } else {
            onFinish?(nil, .cancelled)
        }
    }

    // MARK: - 工具栏
    private func showToolbar() {
        toolbar.isHidden = false
        toolbar.canUndo = !strokes.isEmpty
        toolbar.colorIndex = toolState.colorIndex
        toolbar.lineWidth = toolState.lineWidth
        layoutToolbar()
    }

    private func layoutToolbar() {
        guard !toolbar.isHidden else { return }
        let w = toolbar.barWidth
        let h = toolbar.totalHeight
        var x = selection.maxX - w
        var y = selection.minY - h - 10
        if y < 6 { y = selection.maxY + 10 }                 // 上方
        if y + h > bounds.height - 6 { y = max(6, selection.minY + 10) } // 内部
        x = max(6, min(bounds.width - w - 6, x))
        toolbar.frame = NSRect(x: x, y: y, width: w, height: h)
        toolbar.needsDisplay = true
    }

    private func handleToolbar(_ a: ToolbarAction) {
        commitTextEditor()
        switch a {
        case .tool(let t):
            if annotating && toolState.tool == t {
                annotating = false
                toolbar.activeTool = nil
            } else {
                toolState.tool = t
                annotating = true
                toolbar.activeTool = t
            }
            layoutToolbar()
            updateCursor()
        case .undo:
            if !strokes.isEmpty { strokes.removeLast() }
            toolbar.canUndo = !strokes.isEmpty
        case .cancel:
            onFinish?(nil, .cancelled)
            return
        case .record:
            onFinish?(nil, .record)
            return
        case .save:
            onFinish?(renderResult(), .saved)
            return
        case .done:
            onFinish?(renderResult(), .copied)
            return
        }
        needsDisplay = true
    }

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
        cursorForCurrentState().set()
    }

    private func cursorForCurrentState() -> NSCursor {
        if phase == .picking { return .crosshair }
        if let h = handle(at: mousePoint) {
            switch h {
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            default: return .crosshair
            }
        }
        if annotating && selection.contains(mousePoint) { return .crosshair }
        if selection.contains(mousePoint) { return .openHand }
        return .arrow
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorForCurrentState())
    }

    // MARK: - 文字输入
    private func beginTextEditing(at p: NSPoint) {
        let size = max(13, toolState.lineWidth * 4.5)
        let tv = ScreenshotTextView(frame: NSRect(x: p.x, y: p.y - size - 10,
                                                  width: min(420, max(140, selection.maxX - p.x)),
                                                  height: size + 14))
        tv.isEditable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        tv.textColor = toolState.color
        tv.font = NSFont.systemFont(ofSize: size, weight: .semibold)
        tv.insertionPointColor = toolState.color
        tv.textContainerInset = NSSize(width: 3, height: 3)
        tv.wantsLayer = true
        tv.layer?.cornerRadius = 3
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.onCommit = { [weak self] in self?.commitTextEditor() }
        tv.onCancel = { [weak self] in
            self?.textEditor?.string = ""
            self?.commitTextEditor()
        }
        addSubview(tv)
        textEditor = tv
        window?.makeFirstResponder(tv)
    }

    private func applyEditorStyle() {
        guard let tv = textEditor else { needsDisplay = true; return }
        tv.textColor = toolState.color
        tv.insertionPointColor = toolState.color
        tv.font = NSFont.systemFont(ofSize: max(13, toolState.lineWidth * 4.5), weight: .semibold)
        needsDisplay = true
    }

    private func commitTextEditor() {
        guard let tv = textEditor else { return }
        let content = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = NSPoint(x: tv.frame.minX + 3, y: tv.frame.minY + 3)
        tv.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        guard !content.isEmpty else { return }
        var s = Stroke(tool: .text, color: toolState.color, width: toolState.lineWidth,
                       points: [], start: origin, end: origin)
        s.text = content
        strokes.append(s)
        toolbar.canUndo = true
        needsDisplay = true
    }

    // MARK: - 键盘
    /// 设置后，Esc 先交给它（控制器做去重和「连按强制退出」），再由它回调 handleEscape()
    var onEscapeKey: (() -> Void)?

    /// Esc：正在输入文字 → 取消输入；已有选区 → 回到框选；否则退出截图
    func handleEscape() {
        if let tv = textEditor {
            if tv.hasMarkedText() { tv.unmarkText() }
            tv.string = ""
            commitTextEditor()
            return
        }
        if phase == .selected {
            if let e = NSApp.currentEvent { rightMouseDown(with: e) } else { onFinish?(nil, .cancelled) }
        } else {
            onFinish?(nil, .cancelled)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.keyCode {
        case 53: // ESC：交给控制器统一处理（去重、连按强制退出）
            if let h = onEscapeKey { h() } else { handleEscape() }
            return
        case 36, 76: // Return
            if phase == .selected {
                commitTextEditor()
                onFinish?(renderResult(), .copied)
            }
            return
        default: break
        }

        if mods.contains(.command) {
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case "z": handleToolbar(.undo); return
            case "s": handleToolbar(.save); return
            case "c": handleToolbar(.done); return
            case "r":
                if phase == .selected { handleToolbar(.record) }
                return
            case "a":
                if phase != .selected {
                    selection = bounds; phase = .selected; highlightRect = nil; showToolbar(); needsDisplay = true
                }
                return
            default: return
            }
        }

        guard phase == .selected else { return }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let toolMap: [String: DrawTool] = ["a": .pen, "b": .rect, "c": .ellipse,
                                           "d": .arrow, "m": .mosaic, "t": .text]
        if let t = toolMap[chars] { handleToolbar(.tool(t)); return }
        switch chars {
        case "1", "2", "3", "4", "5", "6":
            let i = Int(chars)! - 1
            if i < ScreenshotToolbar.palette.count {
                toolState.setColorIndex(i)
                toolbar.colorIndex = i
            }
        case "[": toolState.lineWidth = max(1, toolState.lineWidth - 1); toolbar.lineWidth = toolState.lineWidth
        case "]": toolState.lineWidth = min(24, toolState.lineWidth + 1); toolbar.lineWidth = toolState.lineWidth
        default: return
        }
        needsDisplay = true
    }

    // MARK: - 输出
    /// 把选区内容（含标注）渲染成最终图片，按屏幕真实像素输出
    func renderResult() -> NSImage? {
        let r = selection.integral
        guard r.width >= 1, r.height >= 1 else { return nil }

        let pxW = Int((r.width * scale).rounded())
        let pxH = Int((r.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        ctx.interpolationQuality = .high
        ctx.draw(snapshot, in: bounds)

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        drawAnnotations(in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: cg, size: r.size)
        return img
    }
}

/// 截图内嵌文字输入框：⏎ 提交 / ⇧⏎ 换行 / ESC 取消
final class ScreenshotTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:    // Return
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onCommit?()
            }
            return
        case 53:        // ESC：和遮罩其他地方的 Esc 走同一条路径
            if let v = superview as? ScreenshotView, let h = v.onEscapeKey { h() } else { onCancel?() }
            return
        default:
            super.keyDown(with: event)
        }
    }

    /// 随内容自动增高
    override func didChangeText() {
        super.didChangeText()
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        let newH = max(frame.height, used.height + textContainerInset.height * 2 + 4)
        if abs(newH - frame.height) > 0.5 {
            var f = frame
            f.origin.y -= (newH - f.height)
            f.size.height = newH
            frame = f
        }
    }
}
