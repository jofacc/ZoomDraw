import AppKit

enum ToolbarAction: Equatable {
    case tool(DrawTool)
    case undo
    case record        // 录屏当前选区
    case cancel
    case save
    case done          // 复制到剪贴板并结束
}

/// 截图标注工具栏（自绘，参考微信/企业微信的胶囊式工具条）
final class ScreenshotToolbar: NSView {

    struct Item {
        let action: ToolbarAction
        let symbol: String
        let tip: String
        var isSeparator = false
    }

    static let barHeight: CGFloat = 40
    static let optionHeight: CGFloat = 36

    private let items: [Item] = [
        Item(action: .tool(.rect),    symbol: "rectangle",              tip: "矩形 (B)"),
        Item(action: .tool(.ellipse), symbol: "circle",                 tip: "椭圆 (C)"),
        Item(action: .tool(.arrow),   symbol: "arrow.up.right",         tip: "箭头 (D)"),
        Item(action: .tool(.pen),     symbol: "scribble",               tip: "画笔 (A)"),
        Item(action: .tool(.mosaic),  symbol: "square.grid.3x3.fill",   tip: "马赛克 (M)"),
        Item(action: .tool(.text),    symbol: "textformat",             tip: "文字 (T)"),
        Item(action: .undo,           symbol: "arrow.uturn.backward",   tip: "撤销 (⌘Z)", isSeparator: true),
        Item(action: .record,         symbol: "record.circle",          tip: "录屏此区域 (⌘R)", isSeparator: true),
        Item(action: .cancel,         symbol: "xmark",                  tip: "取消 (ESC)", isSeparator: true),
        Item(action: .save,           symbol: "square.and.arrow.down",  tip: "保存 (⌘S)"),
        Item(action: .done,           symbol: "checkmark",              tip: "完成并复制 (↩)")
    ]

    private let itemW: CGFloat = 34
    private let itemH: CGFloat = 28
    private let gap: CGFloat = 4
    private let sepW: CGFloat = 9
    private let pad: CGFloat = 8

    var onAction: ((ToolbarAction) -> Void)?
    var onColorPick: ((Int) -> Void)?
    var onWidthPick: ((CGFloat) -> Void)?

    var activeTool: DrawTool? { didSet { layoutSize(); needsDisplay = true } }
    var colorIndex: Int = 0 { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 4 { didSet { needsDisplay = true } }
    var canUndo: Bool = false { didSet { needsDisplay = true } }

    private var hoverIndex: Int = -1 { didSet { needsDisplay = true } }
    private var itemRects: [Int: NSRect] = [:]
    private var colorRects: [Int: NSRect] = [:]
    private var widthRects: [Int: NSRect] = [:]

    static let palette: [NSColor] = DrawToolState.palette
    private let widths: [CGFloat] = [2, 4, 7, 11]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layoutSize()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// 工具栏总宽
    var barWidth: CGFloat {
        var w = pad * 2
        for (i, it) in items.enumerated() {
            if it.isSeparator && i > 0 { w += sepW }
            w += itemW + (i == items.count - 1 ? 0 : gap)
        }
        return w
    }

    var totalHeight: CGFloat {
        Self.barHeight + (showsOptions ? Self.optionHeight + 2 : 0)
    }

    private var showsOptions: Bool {
        guard let t = activeTool else { return false }
        return t != .mosaic ? true : true    // 马赛克只显示粗细，仍占一行
    }

    private func layoutSize() {
        var f = frame
        f.size = NSSize(width: barWidth, height: totalHeight)
        frame = f
    }

    // MARK: - 绘制
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        itemRects.removeAll(); colorRects.removeAll(); widthRects.removeAll()

        let barRect = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        drawPanel(barRect, ctx: ctx)

        var x = pad
        let y = barRect.minY + (Self.barHeight - itemH) / 2
        for (i, it) in items.enumerated() {
            if it.isSeparator && i > 0 {
                let sx = x + (sepW - 1) / 2 - gap / 2
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                ctx.fill(NSRect(x: sx, y: barRect.minY + 9, width: 1, height: Self.barHeight - 18))
                x += sepW
            }
            let r = NSRect(x: x, y: y, width: itemW, height: itemH)
            itemRects[i] = r
            drawItem(it, index: i, in: r, ctx: ctx)
            x += itemW + gap
        }

        if showsOptions {
            let optRect = NSRect(x: 0, y: 0, width: bounds.width, height: Self.optionHeight)
            drawPanel(optRect, ctx: ctx)
            drawOptions(in: optRect, ctx: ctx)
        }
    }

    private func drawPanel(_ rect: NSRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 0.95).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawItem(_ it: Item, index: Int, in rect: NSRect, ctx: CGContext) {
        var selected = false
        if case .tool(let t) = it.action { selected = (t == activeTool) }

        let enabled = (it.action != .undo) || canUndo

        if selected {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        } else if hoverIndex == index && enabled {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }

        var tint = NSColor.white.withAlphaComponent(0.92)
        if !enabled { tint = NSColor.white.withAlphaComponent(0.28) }
        if case .done = it.action, !selected { tint = NSColor.systemGreen }
        if case .record = it.action, !selected { tint = NSColor.systemRed }
        if case .cancel = it.action, !selected { tint = NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1) }
        if selected { tint = .white }

        drawSymbol(it.symbol, in: rect, color: tint)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) ?? NSImage(systemSymbolName: "square", accessibilityDescription: nil)
        else { return }
        let size = base.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        let tinted = NSImage(size: size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target)
    }

    private func drawOptions(in rect: NSRect, ctx: CGContext) {
        var x = pad + 2
        let cy = rect.midY

        // 粗细
        for (i, w) in widths.enumerated() {
            let r = NSRect(x: x, y: cy - 11, width: 22, height: 22)
            widthRects[i] = r
            let on = abs(w - lineWidth) < 0.5
            if on {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.fillPath()
            }
            let d = 3 + CGFloat(i) * 2.6
            ctx.setFillColor((on ? NSColor.white : NSColor.white.withAlphaComponent(0.6)).cgColor)
            ctx.fillEllipse(in: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
            x += 24
        }

        x += 6
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.fill(NSRect(x: x, y: rect.minY + 9, width: 1, height: rect.height - 18))
        x += 9

        // 颜色（马赛克不需要颜色，置灰但保留布局）
        let colorEnabled = activeTool != .mosaic
        for (i, c) in Self.palette.enumerated() {
            let r = NSRect(x: x, y: cy - 8, width: 16, height: 16)
            colorRects[i] = r
            ctx.saveGState()
            ctx.setFillColor(colorEnabled ? c.cgColor : c.withAlphaComponent(0.25).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
            if i == colorIndex && colorEnabled {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                let ring = r.insetBy(dx: -3, dy: -3)
                ctx.addPath(CGPath(roundedRect: ring, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.strokePath()
            }
            ctx.restoreGState()
            x += 22
        }
    }

    // MARK: - 交互
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in itemRects where r.contains(p) {
            if items[i].action == .undo && !canUndo { return }
            onAction?(items[i].action)
            return
        }
        for (i, r) in colorRects where r.contains(p) {
            if activeTool == .mosaic { return }
            onColorPick?(i); return
        }
        for (i, r) in widthRects where r.contains(p) {
            onWidthPick?(widths[i]); return
        }
    }

    override func mouseDragged(with event: NSEvent) { /* 吞掉，避免穿透到画布 */ }
    override func mouseUp(with event: NSEvent) { /* 吞掉 */ }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hoverIndex = -1 }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var found = -1
        for (i, r) in itemRects where r.contains(p) { found = i }
        hoverIndex = found
        if found >= 0 { toolTip = items[found].tip } else { toolTip = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
