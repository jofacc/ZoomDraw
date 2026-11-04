import AppKit

/// 预览用浮窗：不激活本应用，可在需要时接收键盘
final class PreviewPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var flagsHandler: ((NSEvent) -> Void)?

    init(level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let h = keyHandler, h(event) { return }
        if event.type == .flagsChanged { flagsHandler?(event) }
        super.sendEvent(event)
    }

    /// 毛玻璃圆角背景
    static func makeBackground(frame: NSRect) -> NSVisualEffectView {
        let bg = NSVisualEffectView(frame: frame)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        bg.autoresizingMask = [.width, .height]
        return bg
    }
}

/// 一个窗口的缩略图格子
final class WindowThumbCell: NSView {
    enum Style { case dock, switcher }
    enum Action { case close, minimize, fullscreen }

    private(set) var info: WindowInfo
    let style: Style
    let boxSize: NSSize
    let showTitle: Bool

    var image: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var onAction: ((Action) -> Void)?

    private var hovered = false
    private var hoveredButton: Action?
    private var pressed = false

    private static let pad: CGFloat = 6
    private static let titleH: CGFloat = 22
    private static let btnD: CGFloat = 14

    static func cellSize(thumbWidth: CGFloat, showTitle: Bool) -> NSSize {
        let boxH = (thumbWidth * 0.625).rounded()
        return NSSize(width: thumbWidth + pad * 2, height: boxH + pad * 2 + (showTitle ? titleH : 0))
    }

    init(info: WindowInfo, style: Style, thumbWidth: CGFloat, showTitle: Bool) {
        self.info = info
        self.style = style
        self.showTitle = showTitle
        self.boxSize = NSSize(width: thumbWidth, height: (thumbWidth * 0.625).rounded())
        super.init(frame: NSRect(origin: .zero, size: Self.cellSize(thumbWidth: thumbWidth, showTitle: showTitle)))
        image = WindowThumbnailer.shared.cached(info.windowID)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var boxRect: NSRect {
        NSRect(x: Self.pad, y: Self.pad + (showTitle ? Self.titleH : 0), width: boxSize.width, height: boxSize.height)
    }

    private var hasButtons: Bool { style == .dock && info.axElement != nil }

    private func buttonRect(_ i: Int) -> NSRect {
        let b = boxRect
        return NSRect(x: b.minX + 8 + CGFloat(i) * (Self.btnD + 6), y: b.maxY - 8 - Self.btnD,
                      width: Self.btnD, height: Self.btnD)
    }

    private func button(at p: NSPoint) -> Action? {
        guard hasButtons, hovered else { return nil }
        let actions: [Action] = [.close, .minimize, .fullscreen]
        for (i, a) in actions.enumerated() where buttonRect(i).insetBy(dx: -3, dy: -3).contains(p) { return a }
        return nil
    }

    // MARK: 绘制
    override func draw(_ dirtyRect: NSRect) {
        let bgRect = bounds.insetBy(dx: 1, dy: 1)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 10, yRadius: 10).fill()
        } else if hovered {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 10, yRadius: 10).fill()
        }

        let box = boxRect
        if let img = image, img.size.width > 0, img.size.height > 0 {
            let s = min(box.width / img.size.width, box.height / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            let r = NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: info.isMinimized ? 0.55 : 1)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            if let icon = info.app?.icon {
                let side = min(64, box.height * 0.5)
                icon.draw(in: NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side))
            }
        }

        if let badge = badgeText { drawBadge(badge, in: box) }

        if hasButtons && hovered {
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
            let actions: [Action] = [.close, .minimize, .fullscreen]
            for i in 0..<3 {
                let r = buttonRect(i)
                colors[i].setFill()
                NSBezierPath(ovalIn: r).fill()
                NSColor.black.withAlphaComponent(0.25).setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 0.5; ring.stroke()
                if hoveredButton == actions[i] { drawGlyph(actions[i], in: r) }
            }
        }

        if showTitle {
            var tr = NSRect(x: box.minX + 2, y: 5, width: box.width - 4, height: 15)
            if style == .switcher, let icon = info.app?.icon {
                icon.draw(in: NSRect(x: tr.minX, y: tr.minY - 1, width: 16, height: 16))
                tr.origin.x += 20; tr.size.width -= 20
            }
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            ps.alignment = style == .switcher ? .left : .center
            (info.displayTitle as NSString).draw(in: tr, withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: ps,
            ])
        }
    }

    private var badgeText: String? {
        if info.isMinimized { return "已最小化" }
        if info.isAppHidden { return "已隐藏" }
        if info.isOnOtherSpace { return "其他桌面" }
        return nil
    }

    private func drawBadge(_ s: String, in box: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let sz = (s as NSString).size(withAttributes: attrs)
        let r = NSRect(x: box.midX - sz.width / 2 - 7, y: box.minY + 6, width: sz.width + 14, height: sz.height + 4)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        (s as NSString).draw(at: NSPoint(x: r.minX + 7, y: r.minY + 2), withAttributes: attrs)
    }

    private func drawGlyph(_ a: Action, in r: NSRect) {
        let p = NSBezierPath()
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        let c = NSPoint(x: r.midX, y: r.midY), k: CGFloat = 3.5
        switch a {
        case .close:
            p.move(to: NSPoint(x: c.x - k, y: c.y - k)); p.line(to: NSPoint(x: c.x + k, y: c.y + k))
            p.move(to: NSPoint(x: c.x - k, y: c.y + k)); p.line(to: NSPoint(x: c.x + k, y: c.y - k))
        case .minimize:
            p.move(to: NSPoint(x: c.x - k, y: c.y)); p.line(to: NSPoint(x: c.x + k, y: c.y))
        case .fullscreen:
            p.move(to: NSPoint(x: c.x - k, y: c.y + 1)); p.line(to: NSPoint(x: c.x - k, y: c.y + k))
            p.line(to: NSPoint(x: c.x - 1, y: c.y + k))
            p.move(to: NSPoint(x: c.x + k, y: c.y - 1)); p.line(to: NSPoint(x: c.x + k, y: c.y - k))
            p.line(to: NSPoint(x: c.x + 1, y: c.y - k))
        }
        NSColor.black.withAlphaComponent(0.6).setStroke()
        p.stroke()
    }

    // MARK: 鼠标
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        hoveredButton = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let b = button(at: convert(event.locationInWindow, from: nil))
        if b != hoveredButton { hoveredButton = b; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if let a = button(at: p) { onAction?(a) } else { onClick?() }
    }
}

/// 网格布局：按列数排列格子，第一个在左上
enum ThumbGrid {
    static let spacing: CGFloat = 6

    static func size(count: Int, columns: Int, cell: NSSize) -> NSSize {
        let cols = max(1, min(columns, count))
        let rows = Int(ceil(Double(count) / Double(cols)))
        return NSSize(width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * spacing,
                      height: CGFloat(rows) * cell.height + CGFloat(max(0, rows - 1)) * spacing)
    }

    static func layout(_ cells: [NSView], in container: NSView, origin: NSPoint, columns: Int, cell: NSSize) {
        let cols = max(1, min(columns, cells.count))
        let total = size(count: cells.count, columns: cols, cell: cell)
        for (i, v) in cells.enumerated() {
            let r = i / cols, c = i % cols
            v.frame = NSRect(x: origin.x + CGFloat(c) * (cell.width + spacing),
                             y: origin.y + total.height - CGFloat(r + 1) * cell.height - CGFloat(r) * spacing,
                             width: cell.width, height: cell.height)
            if v.superview !== container { container.addSubview(v) }
        }
    }
}
