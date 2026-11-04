import AppKit

/// 程序坞窗口预览：鼠标停在程序坞图标上时，在图标旁显示该应用全部窗口的缩略图
final class DockPreviewController: NSObject {
    static let shared = DockPreviewController()

    private enum Edge { case bottom, left, right }

    private let panel = PreviewPanel(level: .popUpMenu)
    private var cells: [WindowThumbCell] = []
    private var shownItem: DockWatcher.Item?
    private var showWork: DispatchWorkItem?
    private var loadToken = 0
    private var pollTimer: Timer?
    private var lastInside = Date()
    private var mouseMonitor: Any?
    private var prevFront: NSRunningApplication?
    private var columns = 1
    private var selected: Int? { didSet { cells.enumerated().forEach { $1.isSelected = $0 == selected } } }

    private static let headerH: CGFloat = 30
    private static let pad: CGFloat = 10
    private static let gap: CGFloat = 8

    var isVisible: Bool { panel.isVisible }

    // MARK: 启动
    func startup() {
        DockSettings.registerDefaults()
        panel.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        DockWatcher.shared.onChange = { [weak self] item in self?.dockChanged(item) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .dockSettingsChanged, object: nil)
        settingsChanged()
        promptAccessibilityOnce()
    }

    @objc private func settingsChanged() {
        if DockSettings.previewEnabled {
            DockWatcher.shared.start()
        } else {
            DockWatcher.shared.stop()
            hide(restoreFocus: true)
        }
    }

    func toggleEnabled() {
        DockSettings.previewEnabled.toggle()
        ScreenshotToast.show(DockSettings.previewEnabled ? "已开启程序坞预览" : "已关闭程序坞预览")
    }

    /// 首次启用时说明为什么需要辅助功能权限
    private func promptAccessibilityOnce() {
        let key = "dock.axPrompted"
        guard DockSettings.previewEnabled, !AXIsProcessTrusted(),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "程序坞预览需要「辅助功能」权限"
            alert.informativeText = "用于识别鼠标停在哪个程序坞图标上，以及切换、关闭、最小化窗口。\n授权后无需重启，几秒内自动生效。也可以在「偏好设置 → 程序坞」中关闭此功能。"
            alert.addButton(withTitle: "去授权")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                ClipboardController.requestAccessibility()
            }
        }
    }

    // MARK: 程序坞选中变化
    private func dockChanged(_ item: DockWatcher.Item?) {
        showWork?.cancel()
        showWork = nil
        // 鼠标离开程序坞：交给轮询判断是否进入了预览面板
        guard let item = item else { return }
        guard let pid = item.pid, isEligible(item) else {
            hide(restoreFocus: true)
            return
        }
        if panel.isVisible {
            load(item, pid: pid)
        } else {
            let w = DispatchWorkItem { [weak self] in
                guard DockWatcher.shared.current == item else { return }
                self?.load(item, pid: pid)
            }
            showWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + DockSettings.hoverDelay, execute: w)
        }
    }

    private func isEligible(_ item: DockWatcher.Item) -> Bool {
        guard DockSettings.previewEnabled, !DockSettings.isStageManagerOn else { return false }
        if let bid = item.bundleID, DockSettings.ignoredApps.contains(bid) { return false }
        if item.pid == ProcessInfo.processInfo.processIdentifier { return false }
        return true
    }

    // MARK: 加载与展示
    private func load(_ item: DockWatcher.Item, pid: pid_t) {
        loadToken += 1
        let token = loadToken
        let includeMin = DockSettings.showMinimized, includeOther = DockSettings.showOtherSpaces
        DispatchQueue.global(qos: .userInitiated).async {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            let wins = WindowInventory.windows(of: app, includeMinimized: includeMin, includeOtherSpaces: includeOther)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, token == self.loadToken else { return }
                let stillHere = DockWatcher.shared.current?.pid == pid
                    || (self.panel.isVisible && self.shownItem?.pid == pid)
                guard stillHere else { return }
                if wins.isEmpty { self.hide(restoreFocus: true); return }
                self.present(item, app: app, windows: wins)
            }
        }
    }

    private func present(_ item: DockWatcher.Item, app: NSRunningApplication, windows: [WindowInfo]) {
        let center = NSPoint(x: item.frame.midX, y: item.frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        guard let screen = screen else { return }
        let sf = screen.frame, vf = screen.visibleFrame

        let dB = item.frame.minY - sf.minY, dL = item.frame.minX - sf.minX, dR = sf.maxX - item.frame.maxX
        let edge: Edge = (dB <= dL && dB <= dR) ? .bottom : (dL <= dR ? .left : .right)

        // 计算格子尺寸与列数；放不下就等比缩小
        let showTitle = DockSettings.showTitles
        let maxCols = edge == .bottom ? 8 : 3
        let availW: CGFloat
        switch edge {
        case .bottom: availW = sf.width - 40
        case .left: availW = sf.maxX - item.frame.maxX - Self.gap - 30
        case .right: availW = item.frame.minX - sf.minX - Self.gap - 30
        }
        let availH = edge == .bottom ? (vf.maxY - item.frame.maxY - Self.gap - 10) : (vf.height - 20)
        var scale: CGFloat = 1
        var cell = NSSize.zero, grid = NSSize.zero
        while true {
            cell = WindowThumbCell.cellSize(thumbWidth: (DockSettings.thumbWidth * scale).rounded(), showTitle: showTitle)
            let fit = Int((availW - Self.pad * 2 + ThumbGrid.spacing) / (cell.width + ThumbGrid.spacing))
            columns = max(1, min(maxCols, windows.count, fit))
            grid = ThumbGrid.size(count: windows.count, columns: columns, cell: cell)
            if grid.height + Self.headerH + Self.pad * 2 <= availH || scale < 0.45 { break }
            scale *= 0.85
        }
        let thumbW = cell.width - 12

        let W = max(grid.width + Self.pad * 2, 240)
        let H = grid.height + Self.headerH + Self.pad * 2
        var x: CGFloat, y: CGFloat
        switch edge {
        case .bottom:
            x = item.frame.midX - W / 2
            y = item.frame.maxY + Self.gap
            x = max(sf.minX + 8, min(x, sf.maxX - W - 8))
        case .left, .right:
            x = edge == .left ? item.frame.maxX + Self.gap : item.frame.minX - Self.gap - W
            y = item.frame.midY - H / 2
            y = max(vf.minY + 8, min(y, vf.maxY - H - 8))
        }

        // 重建内容
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let bg = PreviewPanel.makeBackground(frame: content.bounds)
        content.addSubview(bg)
        buildHeader(in: bg, app: app, count: windows.count, width: W, height: H)

        cells = windows.map { info in
            let c = WindowThumbCell(info: info, style: .dock, thumbWidth: thumbW, showTitle: showTitle)
            return c
        }
        for (i, c) in cells.enumerated() {
            c.onClick = { [weak self] in self?.activate(index: i) }
            c.onHover = { [weak self] in if self?.selected != nil { self?.selected = i } }
            c.onAction = { [weak self] a in self?.perform(a, index: i) }
        }
        ThumbGrid.layout(cells, in: bg, origin: NSPoint(x: (W - grid.width) / 2, y: Self.pad),
                         columns: columns, cell: cell)

        let wasVisible = panel.isVisible
        panel.contentView = content
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: W, height: H), display: true)
        shownItem = item
        selected = nil
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
            startTracking()
        }

        let wantedPixel = thumbW * (screen.backingScaleFactor)
        WindowThumbnailer.shared.refresh(windows, maxPixel: wantedPixel) { [weak self] id, img in
            self?.cells.first { $0.info.windowID == id }?.image = img
        }
    }

    private func buildHeader(in bg: NSView, app: NSRunningApplication, count: Int, width W: CGFloat, height H: CGFloat) {
        let y = H - Self.headerH - 2
        let icon = NSImageView(frame: NSRect(x: Self.pad + 4, y: y + 7, width: 18, height: 18))
        icon.image = app.icon
        bg.addSubview(icon)

        let name = NSTextField(labelWithString: app.localizedName ?? "")
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        name.sizeToFit()
        name.frame.origin = NSPoint(x: icon.frame.maxX + 6, y: y + 8)
        name.frame.size.width = min(name.frame.width, W - 200)
        name.lineBreakMode = .byTruncatingTail
        bg.addSubview(name)

        var info = "\(count) 个窗口"
        if !WindowThumbnailer.hasScreenRecordingPermission { info += " · 授予屏幕录制权限后显示画面" }
        let sub = NSTextField(labelWithString: info)
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: name.frame.maxX + 8, y: y + 9, width: max(40, W - name.frame.maxX - 8 - 80), height: 15)
        bg.addSubview(sub)

        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        quit.bezelStyle = .recessed
        quit.controlSize = .small
        quit.font = NSFont.systemFont(ofSize: 11)
        quit.contentTintColor = .systemRed
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: W - Self.pad - quit.frame.width - 2, y: y + 5)
        bg.addSubview(quit)
    }

    // MARK: 动作
    private func activate(index i: Int) {
        guard i < cells.count else { return }
        let info = cells[i].info
        hide(restoreFocus: false)
        WindowInventory.focus(info)
    }

    private func perform(_ a: WindowThumbCell.Action, index i: Int) {
        guard i < cells.count, let item = shownItem, let pid = item.pid else { return }
        let info = cells[i].info
        switch a {
        case .close:
            WindowInventory.close(info)
            reload(item, pid: pid, after: 0.35)
        case .minimize:
            WindowInventory.toggleMinimize(info)
            reload(item, pid: pid, after: 0.45)
        case .fullscreen:
            hide(restoreFocus: false)
            WindowInventory.toggleFullScreen(info)
        }
    }

    private func reload(_ item: DockWatcher.Item, pid: pid_t, after: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self = self, self.panel.isVisible, self.shownItem?.pid == pid else { return }
            self.load(item, pid: pid)
        }
    }

    @objc private func quitApp() {
        guard let pid = shownItem?.pid else { return }
        hide(restoreFocus: true)
        WindowInventory.quit(pid: pid)
    }

    // MARK: 键盘（鼠标进入面板后可用）
    private func handleKey(_ e: NSEvent) -> Bool {
        let n = cells.count
        guard n > 0 else { return false }
        switch e.keyCode {
        case 53: hide(restoreFocus: true); return true
        case 36, 76, 49:
            if let s = selected { activate(index: s) }
            return true
        case 123: selected = max(0, (selected ?? 1) - 1); return true
        case 124: selected = min(n - 1, (selected ?? -1) + 1); return true
        case 126: selected = max(0, (selected ?? 0) - columns); return true
        case 125: selected = min(n - 1, (selected ?? -columns) + columns); return true
        default: return false
        }
    }

    // MARK: 收起判断
    private func startTracking() {
        lastInside = Date()
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                // 点到面板以外（包括点程序坞图标本身）就收起
                self?.hide(restoreFocus: false)
            }
        }
    }

    private func poll() {
        guard panel.isVisible, let item = shownItem else { return }
        let m = NSEvent.mouseLocation
        let inPanel = panel.frame.insetBy(dx: -4, dy: -4).contains(m)
        // 图标与面板之间的区域也算在内，避免鼠标从图标移向面板时闪退
        let zone = panel.frame.union(item.frame).insetBy(dx: -2, dy: -2)
        if zone.contains(m) || DockWatcher.shared.current?.pid == item.pid {
            lastInside = Date()
        } else if Date().timeIntervalSince(lastInside) > 0.22 {
            hide(restoreFocus: true)
            return
        }
        // 鼠标进入面板后接收键盘（←→ 选择、⏎ 切换、Esc 关闭）
        if inPanel && !panel.isKeyWindow {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { prevFront = front }
            panel.makeKey()
        }
    }

    func hide(restoreFocus: Bool) {
        showWork?.cancel()
        showWork = nil
        loadToken += 1
        guard panel.isVisible else { return }
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        pollTimer?.invalidate()
        pollTimer = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        cells = []
        shownItem = nil
        if wasKey && restoreFocus, let p = prevFront, !p.isTerminated {
            p.activate()
        }
        prevFront = nil
    }
}
