import AppKit
import QuickLookThumbnailing

/// 暂存板浮窗：无边框、置顶、可跨 Space，可拖动
final class ShelfWindow: NSWindow {
    let shelfView: ShelfContentView

    init(frame: NSRect) {
        shelfView = ShelfContentView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame,
                   styleMask: [.borderless, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 260, height: 200)
        maxSize = NSSize(width: 640, height: 900)
        contentView = shelfView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 仅在「贴边收起 / 展开」的程序化移动期间允许窗口移出屏幕。
    /// 其余时候（尤其是用户手动拖动）必须约束在屏内，否则窗口会被拖到点不到的地方。
    var allowsOffscreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : ShelfWindow.reachableFrame(frameRect)
    }

    /// 把矩形夹在「可见区域」内，保证窗口任何时候都能被鼠标抓到
    static func reachableFrame(_ rect: NSRect) -> NSRect {
        // 取与之重叠面积最大的屏；完全不重叠时退回主屏
        var target: NSScreen? = nil
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(rect)
            let area = i.width * i.height
            if area > bestArea { bestArea = area; target = s }
        }
        guard let vf = (target ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return rect }
        var f = rect
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = max(vf.minX, min(vf.maxX - f.width, f.origin.x))
        f.origin.y = max(vf.minY, min(vf.maxY - f.height, f.origin.y))
        return f
    }

    /// 当前位置是否完全可达（用于修复历史遗留的屏外坐标）
    var isReachable: Bool {
        abs(ShelfWindow.reachableFrame(frame).origin.x - frame.origin.x) < 1
            && abs(ShelfWindow.reachableFrame(frame).origin.y - frame.origin.y) < 1
    }
}

// MARK: - 可拖动窗口的基类
/// 不使用 `NSWindow.performDrag`：它会进入 AppKit 的嵌套事件循环，
/// 拖动结束的时机与窗口最终位置都不可靠（贴边判断因此失效）。
/// 这里自己处理 down/dragged/up，松手时机与坐标完全可控。
class ShelfDraggableView: NSView {
    /// 正在拖动窗口
    var onWindowDragging: (() -> Void)?
    /// 拖动窗口结束（鼠标已松开，窗口位置已确定）
    var onWindowDragEnded: (() -> Void)?

    private var windowOriginAtDown: NSPoint = .zero
    private var mouseAtDown: NSPoint = .zero
    private var isDraggingWindow = false

    /// 子类在确认「此次按下应该拖窗口」时调用
    final func beginWindowDrag() {
        guard let w = window else { return }
        windowOriginAtDown = w.frame.origin
        mouseAtDown = NSEvent.mouseLocation
        isDraggingWindow = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingWindow, let w = window else {
            super.mouseDragged(with: event); return
        }
        let now = NSEvent.mouseLocation
        var f = w.frame
        f.origin = NSPoint(x: windowOriginAtDown.x + (now.x - mouseAtDown.x),
                           y: windowOriginAtDown.y + (now.y - mouseAtDown.y))
        // setFrameOrigin 不一定经过 constrainFrameRect，这里显式夹住，
        // 确保用户无论怎么拖都不会把窗口拖到屏幕外抓不回来
        w.setFrame(ShelfWindow.reachableFrame(f), display: true)
        onWindowDragging?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingWindow else { super.mouseUp(with: event); return }
        isDraggingWindow = false
        onWindowDragEnded?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 内容视图（标题栏 + 网格）
final class ShelfContentView: ShelfDraggableView {
    var onClose: (() -> Void)?
    /// 鼠标进入 / 离开（供自动隐藏逻辑使用）
    var onHoverChange: ((Bool) -> Void)?
    /// 点击贴边细条，请求展开
    var onExpandRequest: (() -> Void)?

    private let titleBarH: CGFloat = 34
    private let grid = ShelfGridView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var titleBar: ShelfTitleBar!
    /// 贴边收起时覆盖在最上层的抓手条
    private let edgeHandle = ShelfEdgeHandle(frame: .zero)

    /// 贴边收起的方向；nil 表示展开状态
    var collapsedEdge: ShelfController.Edge? {
        didSet { updateEdgeHandle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        titleBar = ShelfTitleBar(frame: NSRect(x: 0, y: frameRect.height - titleBarH,
                                               width: frameRect.width, height: titleBarH))
        titleBar.autoresizingMask = [.width, .minYMargin]
        titleBar.onClose = { [weak self] in self?.onClose?() }
        titleBar.onClear = { ShelfStore.shared.removeAll() }
        // 标题栏上的拖动同样转交给控制器做贴边判断
        titleBar.onWindowDragging = { [weak self] in self?.onWindowDragging?() }
        titleBar.onWindowDragEnded = { [weak self] in self?.onWindowDragEnded?() }
        addSubview(titleBar)

        scroll.frame = NSRect(x: 0, y: 0, width: frameRect.width, height: frameRect.height - titleBarH)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.documentView = grid
        addSubview(scroll)

        grid.autoresizingMask = [.width]
        grid.onCountChange = { [weak self] in self?.refreshTitle() }
        refreshTitle()

        edgeHandle.isHidden = true
        edgeHandle.onClick = { [weak self] in self?.onExpandRequest?() }
        addSubview(edgeHandle, positioned: .above, relativeTo: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(onShelfChanged),
                                               name: .shelfChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onShelfChanged() {
        grid.reload()
        refreshTitle()
    }

    private func refreshTitle() {
        titleBar.itemCount = ShelfStore.shared.count
    }

    func reload() {
        grid.reload()
        refreshTitle()
    }

    /// 空白区域按下即拖窗口
    override func mouseDown(with event: NSEvent) {
        guard collapsedEdge == nil else { onExpandRequest?(); return }
        beginWindowDrag()
    }

    /// 摆放抓手条：覆盖露出屏幕的那一条，且位于最上层以便接收点击
    private func updateEdgeHandle() {
        guard let edge = collapsedEdge else {
            edgeHandle.isHidden = true
            return
        }
        let t = ShelfController.peek
        switch edge {
        case .left:  edgeHandle.frame = NSRect(x: bounds.maxX - t, y: 0, width: t, height: bounds.height)
        case .right: edgeHandle.frame = NSRect(x: 0, y: 0, width: t, height: bounds.height)
        case .top:   edgeHandle.frame = NSRect(x: 0, y: 0, width: bounds.width, height: t)
        }
        edgeHandle.edge = edge
        edgeHandle.isHidden = false
        edgeHandle.needsDisplay = true
        window?.invalidateCursorRects(for: edgeHandle)
    }

    // MARK: 悬停跟踪
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func layout() {
        super.layout()
        // 网格宽度跟随，随内容自适应高度
        grid.frame.size.width = scroll.contentSize.width
        grid.relayout()
        updateEdgeHandle()
    }
}

// MARK: - 贴边抓手条
/// 收起后唯一留在屏幕内的部分：点击即可把暂存板拉回
final class ShelfEdgeHandle: NSView {
    var onClick: (() -> Void)?
    var edge: ShelfController.Edge = .right

    private var hover = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.controlAccentColor
            .withAlphaComponent(hover ? 1.0 : 0.85).cgColor)
        ctx.fill(bounds)

        // 中间画一小段浅色握把，暗示可点击
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        switch edge {
        case .left, .right:
            let h: CGFloat = min(30, bounds.height * 0.2)
            ctx.fill(NSRect(x: bounds.midX - 1, y: bounds.midY - h / 2, width: 2, height: h))
        case .top:
            let w: CGFloat = min(30, bounds.width * 0.2)
            ctx.fill(NSRect(x: bounds.midX - w / 2, y: bounds.midY - 1, width: w, height: 2))
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 标题栏
private final class ShelfTitleBar: ShelfDraggableView {
    var onClose: (() -> Void)?
    var onClear: (() -> Void)?

    var itemCount: Int = 0 { didSet { needsDisplay = true } }

    private var closeRect: NSRect = .zero
    private var clearRect: NSRect = .zero
    private var hover = -1 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))

        let title = (itemCount == 0 ? "暂存板" : "暂存板 · \(itemCount)") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let ts = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: 12, y: (bounds.height - ts.height) / 2), withAttributes: attrs)

        let btn: CGFloat = 22
        closeRect = NSRect(x: bounds.width - 10 - btn, y: (bounds.height - btn) / 2, width: btn, height: btn)
        clearRect = NSRect(x: closeRect.minX - btn - 2, y: closeRect.minY, width: btn, height: btn)

        drawButton(clearRect, symbol: "trash", index: 0,
                   color: itemCount == 0 ? NSColor.white.withAlphaComponent(0.25)
                                         : NSColor.white.withAlphaComponent(0.8), ctx: ctx)
        drawButton(closeRect, symbol: "xmark", index: 1,
                   color: NSColor.white.withAlphaComponent(0.8), ctx: ctx)
    }

    private func drawButton(_ r: NSRect, symbol: String, index: Int, color: NSColor, ctx: CGContext) {
        if hover == index {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return }
        let size = base.size
        base.tinted(with: color).draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2,
                                                width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        if clearRect.contains(p) {
            guard itemCount > 0 else { return }
            onClear?()
            return
        }
        beginWindowDrag()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = clearRect.contains(p) ? 0 : (closeRect.contains(p) ? 1 : -1)
        toolTip = hover == 0 ? "清空暂存板" : (hover == 1 ? "隐藏暂存板" : "拖动可移动窗口")
    }
    override func mouseExited(with event: NSEvent) { hover = -1 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - 网格
final class ShelfGridView: NSView, NSDraggingSource {

    var onCountChange: (() -> Void)?

    private var items: [ShelfItem] = ShelfStore.shared.items
    private var selected: Set<UUID> = []
    private var hoverIndex = -1 { didSet { needsDisplay = true } }
    private var isDropTarget = false { didSet { needsDisplay = true } }

    private var mouseDownIndex: Int?
    private var mouseDownPoint: NSPoint = .zero
    private var dragStarted = false
    /// 拉框多选
    private var marqueeRect: NSRect?
    private var marqueeBase: Set<UUID> = []
    private var marqueeAdditive = false

    private let itemW: CGFloat = 74
    private let itemH: CGFloat = 86
    private let gapX: CGFloat = 8
    private let gapY: CGFloat = 8
    private let inset: CGFloat = 12
    private let iconSide: CGFloat = 44

    private var columns = 3
    private var thumbCache: [String: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(ShelfStore.acceptedDragTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 关键：窗口未激活时第一次点击也直接作用于内容，
    /// 不需要先点一下窗口「激活」再点文件，保证拖拽操作的连续性
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        items = ShelfStore.shared.items
        selected = selected.filter { id in items.contains { $0.id == id } }
        relayout()
        needsDisplay = true
        onCountChange?()
    }

    /// 依据宽度重算列数与自身高度
    func relayout() {
        let usable = max(itemW, bounds.width - inset * 2)
        columns = max(1, Int((usable + gapX) / (itemW + gapX)))
        let rows = max(1, Int(ceil(Double(items.count) / Double(columns))))
        let h = inset * 2 + CGFloat(rows) * itemH + CGFloat(max(0, rows - 1)) * gapY
        let minH = (superview as? NSClipView)?.bounds.height ?? h
        let newH = max(h, minH)
        if abs(frame.height - newH) > 0.5 {
            frame.size.height = newH
        }
        needsDisplay = true
    }

    private func frameForItem(_ index: Int) -> NSRect {
        let row = index / columns
        let col = index % columns
        return NSRect(x: inset + CGFloat(col) * (itemW + gapX),
                      y: inset + CGFloat(row) * (itemH + gapY),
                      width: itemW, height: itemH)
    }

    private func indexAt(_ p: NSPoint) -> Int? {
        for i in items.indices where frameForItem(i).contains(p) { return i }
        return nil
    }

    // MARK: - 绘制
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if items.isEmpty {
            drawEmptyState(ctx: ctx)
        } else {
            for (i, item) in items.enumerated() {
                drawItem(item, index: i, in: frameForItem(i), ctx: ctx)
            }
        }

        if let m = marqueeRect, m.width > 1 || m.height > 1 {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
            ctx.fill(m)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }

        if isDropTarget {
            let r = bounds.insetBy(dx: 4, dy: 4)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [7, 4])
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.strokePath()
        }
    }

    private func drawEmptyState(ctx: CGContext) {
        let lines: [(String, NSFont, NSColor)] = [
            ("把文件拖到这里", NSFont.systemFont(ofSize: 13, weight: .medium), NSColor.white.withAlphaComponent(0.75)),
            ("再从这里拖到目标应用", NSFont.systemFont(ofSize: 11), NSColor.white.withAlphaComponent(0.4)),
            ("也支持文本、图片、网址", NSFont.systemFont(ofSize: 11), NSColor.white.withAlphaComponent(0.4))
        ]
        if let base = NSImage(systemSymbolName: "tray.and.arrow.down",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)) {
            let s = base.size
            base.tinted(with: NSColor.white.withAlphaComponent(0.32))
                .draw(in: NSRect(x: bounds.midX - s.width / 2,
                                 y: bounds.midY - 52, width: s.width, height: s.height))
        }
        var y = bounds.midY + 2
        for (text, font, color) in lines {
            let ns = text as NSString
            let size = ns.size(withAttributes: [.font: font])
            ns.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y),
                    withAttributes: [.font: font, .foregroundColor: color])
            y += size.height + 4
        }
    }

    private func drawItem(_ item: ShelfItem, index: Int, in rect: NSRect, ctx: CGContext) {
        let isSelected = selected.contains(item.id)
        if isSelected || hoverIndex == index {
            ctx.setFillColor((isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.32)
                                         : NSColor.white.withAlphaComponent(0.09)).cgColor)
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                               cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
        }

        let icon = thumbnail(for: item)
        let box = NSRect(x: rect.midX - iconSide / 2, y: rect.minY + 8, width: iconSide, height: iconSide)
        let fitted = Self.fit(size: icon.size, into: box)
        icon.draw(in: fitted, from: .zero, operation: .sourceOver,
                  fraction: item.exists ? 1.0 : 0.35)

        // 文件名（两行内截断）
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: item.exists ? NSColor.white.withAlphaComponent(0.85)
                                          : NSColor.systemOrange.withAlphaComponent(0.85),
            .paragraphStyle: para
        ]
        let textRect = NSRect(x: rect.minX + 3, y: box.maxY + 5, width: rect.width - 6, height: 26)
        (item.displayName as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private static func fit(size: NSSize, into box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let ratio = min(box.width / size.width, box.height / size.height)
        let w = size.width * ratio, h = size.height * ratio
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    // MARK: - 缩略图
    private func thumbnail(for item: ShelfItem) -> NSImage {
        if let cached = thumbCache[item.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        icon.size = NSSize(width: iconSide, height: iconSide)
        thumbCache[item.path] = icon
        requestQuickLookThumbnail(for: item)
        return icon
    }

    /// 异步换成 QuickLook 真实预览（图片、PDF 等能看到内容）
    private func requestQuickLookThumbnail(for item: ShelfItem) {
        guard item.exists else { return }
        let scale = window?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: item.url,
                                              size: CGSize(width: iconSide, height: iconSide),
                                              scale: scale,
                                              representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep = rep else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let img = NSImage(cgImage: rep.cgImage, size: rep.contentRect.size)
                self.thumbCache[item.path] = img
                self.needsDisplay = true
            }
        }
    }

    // MARK: - 鼠标：选择 / 拖出 / 打开 / 拉框
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        dragStarted = false
        marqueeRect = nil
        let idx = indexAt(p)
        mouseDownIndex = idx

        guard let idx = idx else {
            // 空白处按下：准备拉框多选（按住 ⌘/⇧ 为追加选择）
            marqueeAdditive = event.modifierFlags.contains(.command)
                || event.modifierFlags.contains(.shift)
            marqueeBase = marqueeAdditive ? selected : []
            if !marqueeAdditive { selected.removeAll() }
            needsDisplay = true
            return
        }
        let id = items[idx].id

        if event.clickCount >= 2 {
            NSWorkspace.shared.open(items[idx].url)
            return
        }
        if event.modifierFlags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else if !selected.contains(id) {
            selected = [id]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 空白处起手 → 拉框多选
        guard let idx = mouseDownIndex, idx < items.count else {
            let r = NSRect(x: min(mouseDownPoint.x, p.x), y: min(mouseDownPoint.y, p.y),
                           width: abs(p.x - mouseDownPoint.x), height: abs(p.y - mouseDownPoint.y))
            marqueeRect = r
            var hit = marqueeBase
            for i in items.indices where frameForItem(i).intersects(r) {
                hit.insert(items[i].id)
            }
            selected = hit
            autoscroll(with: event)
            needsDisplay = true
            return
        }

        // 文件上起手 → 拖出
        guard !dragStarted else { return }
        guard hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 4 else { return }
        dragStarted = true

        // 拖动已选中的项 → 整批拖出；否则只拖当前项
        var indices: [Int]
        if selected.contains(items[idx].id) {
            indices = items.indices.filter { selected.contains(items[$0].id) }
        } else {
            indices = [idx]
            selected = [items[idx].id]
            needsDisplay = true
        }

        var dragItems: [NSDraggingItem] = []
        for i in indices {
            let item = items[i]
            guard item.exists else { continue }
            let di = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let box = frameForItem(i)
            let icon = thumbnail(for: item)
            di.setDraggingFrame(Self.fit(size: icon.size,
                                         into: NSRect(x: box.midX - iconSide / 2, y: box.minY + 8,
                                                      width: iconSide, height: iconSide)),
                                contents: icon)
            dragItems.append(di)
        }
        guard !dragItems.isEmpty else { return }
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeRect != nil {
            marqueeRect = nil
            marqueeBase = []
            needsDisplay = true
        }
        mouseDownIndex = nil
        dragStarted = false
    }

    override func mouseMoved(with event: NSEvent) {
        hoverIndex = indexAt(convert(event.locationInWindow, from: nil)) ?? -1
        if hoverIndex >= 0, hoverIndex < items.count {
            let it = items[hoverIndex]
            toolTip = it.exists ? it.path : "\(it.path)\n（源文件已不存在）"
        } else {
            toolTip = nil
        }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = -1 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    // MARK: - 键盘
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:   // Delete / Forward Delete
            removeSelected()
            return
        case 49:        // Space → 预览
            if let id = selected.first, let item = items.first(where: { $0.id == id }) {
                NSWorkspace.shared.open(item.url)
            }
            return
        case 36, 76:    // Return → 打开
            for item in items where selected.contains(item.id) { NSWorkspace.shared.open(item.url) }
            return
        default: break
        }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.modifierFlags.contains(.command) {
            switch chars {
            case "a": selected = Set(items.map(\.id)); needsDisplay = true; return
            case "c": copySelectedToPasteboard(); return
            case "v": ShelfStore.shared.ingest(from: .general); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    private func removeSelected() {
        guard !selected.isEmpty else { return }
        ShelfStore.shared.remove(ids: selected)
        selected.removeAll()
    }

    private func copySelectedToPasteboard() {
        let urls = items.filter { selected.contains($0.id) && $0.exists }.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
        ScreenshotToast.show("已复制 \(urls.count) 个文件")
    }

    // MARK: - 右键菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = indexAt(p) {
            if !selected.contains(items[idx].id) { selected = [items[idx].id]; needsDisplay = true }
        } else {
            selected.removeAll(); needsDisplay = true
        }

        let menu = NSMenu()
        if !selected.isEmpty {
            menu.addItem(withTitle: "打开", action: #selector(ctxOpen), keyEquivalent: "")
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(ctxReveal), keyEquivalent: "")
            menu.addItem(withTitle: "复制", action: #selector(ctxCopy), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "从暂存板移除", action: #selector(ctxRemove), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "粘贴到暂存板", action: #selector(ctxPaste), keyEquivalent: "")
        menu.addItem(withTitle: "清理失效条目", action: #selector(ctxPrune), keyEquivalent: "")
        menu.addItem(withTitle: "清空暂存板", action: #selector(ctxClear), keyEquivalent: "")
        for i in menu.items { i.target = self }
        return menu
    }

    @objc private func ctxOpen() {
        for item in items where selected.contains(item.id) { NSWorkspace.shared.open(item.url) }
    }
    @objc private func ctxReveal() {
        let urls = items.filter { selected.contains($0.id) }.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    @objc private func ctxCopy() { copySelectedToPasteboard() }
    @objc private func ctxRemove() { removeSelected() }
    @objc private func ctxPaste() {
        let n = ShelfStore.shared.ingest(from: .general)
        ScreenshotToast.show(n > 0 ? "已加入暂存板" : "剪贴板中没有可暂存的内容")
    }
    @objc private func ctxPrune() {
        let n = ShelfStore.shared.pruneMissing()
        ScreenshotToast.show(n > 0 ? "已清理 \(n) 个失效条目" : "没有失效条目")
    }
    @objc private func ctxClear() { ShelfStore.shared.removeAll() }

    // MARK: - 拖入
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let added = ShelfStore.shared.ingest(from: sender.draggingPasteboard)
        if added > 0 {
            ScreenshotToast.show("已加入暂存板 · \(added) 项")
            return true
        }
        ScreenshotToast.show("暂存板不支持该内容")
        return false
    }

    // MARK: - NSDraggingSource（拖出）
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 拖到其他应用一律按「复制」，避免原文件被移动
        context == .outsideApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragStarted = false
        mouseDownIndex = nil
    }
}
