import AppKit

/// ⌥Tab 窗口切换器：按住修饰键连按 Tab 选择，松开即切换到选中的窗口
final class WindowSwitcherController: NSObject {
    static let shared = WindowSwitcherController()

    private let panel = PreviewPanel(level: .modalPanel)
    private var windows: [WindowInfo] = []
    private var cells: [WindowThumbCell] = []
    private var columns = 1
    private var selected = 0 { didSet { cells.enumerated().forEach { $1.isSelected = $0 == selected } } }

    /// 需要保持按住的修饰键；从菜单打开时为空（不靠松开修饰键提交）
    private var holdMods: NSEvent.ModifierFlags = []
    private var modTimer: Timer?
    private var loading = false
    private var pendingSteps = 0
    private var commitWhenReady = false
    private var prevFront: NSRunningApplication?
    private var token = 0

    private static let pad: CGFloat = 14

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        panel.flagsHandler = { [weak self] _ in self?.checkModifiers() }
    }

    // MARK: 入口

    /// 全局快捷键按下：未显示则打开，已显示则选下一个
    func hotkeyPressed() {
        guard DockSettings.switcherEnabled else { return }
        if panel.isVisible || loading {
            step(+1)
            return
        }
        let b = HotkeyConfig.shared.binding(for: .windowSwitcher)
        open(holding: b.modifierFlags.intersection([.command, .option, .control, .shift]))
    }

    /// 从菜单打开：不需要按住修饰键，用方向键 / ⏎ / 点击选择
    func openSticky() {
        open(holding: [])
    }

    private func open(holding mods: NSEvent.ModifierFlags) {
        DockPreviewController.shared.hide(restoreFocus: false)
        holdMods = mods
        commitWhenReady = false
        pendingSteps = 0
        loading = true
        token += 1
        let t = token
        let front = NSWorkspace.shared.frontmostApplication
        prevFront = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        if !mods.isEmpty { startModifierWatch() }

        let includeMin = DockSettings.showMinimized, includeOther = DockSettings.showOtherSpaces
        DispatchQueue.global(qos: .userInteractive).async {
            let list = WindowInventory.allWindows(includeMinimized: includeMin, includeOtherSpaces: includeOther)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, t == self.token else { return }
                self.loading = false
                self.ready(list)
            }
        }
    }

    private func ready(_ list: [WindowInfo]) {
        guard !list.isEmpty else {
            stopModifierWatch()
            ScreenshotToast.show("没有可切换的窗口")
            return
        }
        windows = list
        // 默认选中「上一个」窗口，快速点按一次即可在两个窗口间来回切换
        selected = 0
        let start = (list.count > 1 && list[0].isOnCurrentSpace) ? 1 : 0
        let steps = pendingSteps
        pendingSteps = 0

        // 松开得比加载还快：直接切换，不显示面板
        if commitWhenReady {
            let idx = (start + steps) % list.count
            stopModifierWatch()
            WindowInventory.focus(list[idx])
            return
        }
        present()
        selected = (start + steps) % list.count
    }

    // MARK: 展示
    private func present() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let vf = screen.visibleFrame
        let n = windows.count

        var scale: CGFloat = 1
        var cell = NSSize.zero, grid = NSSize.zero
        while true {
            cell = WindowThumbCell.cellSize(thumbWidth: (DockSettings.thumbWidth * scale).rounded(), showTitle: true)
            let fit = Int((vf.width * 0.9 - Self.pad * 2 + ThumbGrid.spacing) / (cell.width + ThumbGrid.spacing))
            columns = max(1, min(n, fit, 7))
            grid = ThumbGrid.size(count: n, columns: columns, cell: cell)
            if grid.height + Self.pad * 2 <= vf.height * 0.85 || scale < 0.4 { break }
            scale *= 0.85
        }
        let thumbW = cell.width - 12
        let W = grid.width + Self.pad * 2, H = grid.height + Self.pad * 2

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let bg = PreviewPanel.makeBackground(frame: content.bounds)
        bg.layer?.cornerRadius = 18
        content.addSubview(bg)

        cells = windows.map { WindowThumbCell(info: $0, style: .switcher, thumbWidth: thumbW, showTitle: true) }
        for (i, c) in cells.enumerated() {
            c.onHover = { [weak self] in self?.selected = i }
            c.onClick = { [weak self] in self?.selected = i; self?.commit() }
        }
        ThumbGrid.layout(cells, in: bg, origin: NSPoint(x: Self.pad, y: Self.pad), columns: columns, cell: cell)

        panel.contentView = content
        panel.setFrame(NSRect(x: (vf.midX - W / 2).rounded(), y: (vf.midY - H / 2).rounded(), width: W, height: H),
                       display: true)
        panel.makeKeyAndOrderFront(nil)

        WindowThumbnailer.shared.refresh(windows, maxPixel: thumbW * screen.backingScaleFactor) { [weak self] id, img in
            self?.cells.first { $0.info.windowID == id }?.image = img
        }
    }

    private func step(_ d: Int) {
        if loading { pendingSteps += 1; return }
        guard !windows.isEmpty, panel.isVisible else { return }
        selected = (selected + d + windows.count) % windows.count
    }

    // MARK: 提交 / 取消
    private func commit() {
        guard panel.isVisible, selected < windows.count else { return }
        let target = windows[selected]
        close()
        WindowInventory.focus(target)
    }

    private func cancel() {
        let wasKey = panel.isKeyWindow
        close()
        if wasKey, let p = prevFront, !p.isTerminated { p.activate() }
    }

    private func close() {
        token += 1
        loading = false
        stopModifierWatch()
        panel.orderOut(nil)
        cells = []
        windows = []
    }

    // MARK: 修饰键松开检测
    private func startModifierWatch() {
        modTimer?.invalidate()
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.checkModifiers() }
        RunLoop.main.add(t, forMode: .common)
        modTimer = t
    }

    private func stopModifierWatch() {
        modTimer?.invalidate()
        modTimer = nil
        holdMods = []
    }

    private func checkModifiers() {
        guard !holdMods.isEmpty else { return }
        let now = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !now.isSuperset(of: holdMods) else { return }
        if loading {
            commitWhenReady = true
        } else {
            commit()
        }
    }

    // MARK: 键盘
    private func handleKey(_ e: NSEvent) -> Bool {
        let n = windows.count
        guard n > 0 else { return false }
        switch e.keyCode {
        case 53: cancel(); return true                                         // Esc
        case 36, 76, 49: commit(); return true                                 // ⏎ / Space
        case 48: step(e.modifierFlags.contains(.shift) ? -1 : 1); return true  // Tab / ⇧Tab
        case 123: step(-1); return true
        case 124: step(+1); return true
        case 126: selected = max(0, selected - columns); return true
        case 125: selected = min(n - 1, selected + columns); return true
        case 13: // W：关闭选中窗口
            WindowInventory.close(windows[selected]); refreshSoon(); return true
        case 46: // M：最小化 / 还原
            WindowInventory.toggleMinimize(windows[selected]); refreshSoon(); return true
        case 12: // Q：退出应用
            WindowInventory.quit(pid: windows[selected].pid); refreshSoon(after: 0.6); return true
        default: return true   // 切换器打开时吞掉其他按键，避免误输入
        }
    }

    /// 关闭 / 最小化 / 退出后重新列出窗口，保持当前选中位置
    private func refreshSoon(after: TimeInterval = 0.35) {
        let keep = selected
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self = self, t == self.token, self.panel.isVisible else { return }
            let includeMin = DockSettings.showMinimized, includeOther = DockSettings.showOtherSpaces
            DispatchQueue.global(qos: .userInteractive).async {
                let list = WindowInventory.allWindows(includeMinimized: includeMin, includeOtherSpaces: includeOther)
                DispatchQueue.main.async {
                    guard t == self.token, self.panel.isVisible else { return }
                    if list.isEmpty { self.cancel(); return }
                    self.windows = list
                    self.present()
                    self.selected = min(keep, list.count - 1)
                }
            }
        }
    }
}
