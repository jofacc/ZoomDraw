import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let zoom = ZoomController()
    private let draw = DrawController()
    private let shot = ScreenshotController()
    private let hotkeys = HotkeyManager()
    private var hotkeyIDs: [HotkeyAction: UInt32] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardSettings.registerDefaults()
        DockSettings.registerDefaults()
        setupStatusItem()
        applyHotkeys()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onHotkeysChanged),
            name: .hotkeysChanged, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(onShelfChanged),
            name: .shelfChanged, object: nil)
        RecordingController.shared.onStateChange = { [weak self] _ in
            self?.updateStatusIcon()
            self?.rebuildMenu()
        }
        NotificationCenter.default.addObserver(self,
            selector: #selector(onShelfChanged),
            name: .clipboardStateChanged, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(onShelfChanged),
            name: .dockSettingsChanged, object: nil)
        ShelfController.shared.startup()
        ClipboardStore.shared.startup()
        DockPreviewController.shared.startup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardStore.shared.flush()
    }

    /// 关键：关闭最后一个窗口不要退出 app（菜单栏应用必须）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        updateStatusIcon()
        rebuildMenu()
    }

    /// 录屏进行中把菜单栏图标换成红色圆点，便于随时感知状态
    private func updateStatusIcon() {
        guard let btn = statusItem?.button else { return }
        if RecordingController.shared.isRecording {
            if let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "录屏中") {
                btn.image = img.tinted(with: .systemRed)
                btn.title = ""
            } else {
                btn.image = nil
                btn.title = "●"
            }
            btn.toolTip = "ZoomDraw — 录屏中"
            return
        }
        // 用荧光笔图标，与"屏幕放大+标注"工具语义贴合，且菜单栏不易混淆
        let img = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "ZoomDraw")
            ?? NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "ZoomDraw")
        if let img = img {
            img.isTemplate = true
            btn.image = img
            btn.title = ""
        } else {
            btn.image = nil
            btn.title = "✎"
        }
        btn.toolTip = "ZoomDraw"
    }

    /// 菜单项后面显示的快捷键；未设置时不显示
    private func keySuffix(_ a: HotkeyAction) -> String {
        let b = HotkeyConfig.shared.binding(for: a)
        return b.isNone ? "" : "  (\(b.displayString))"
    }

    private func rebuildMenu() {

        let menu = NSMenu()
        if RecordingController.shared.isRecording {
            menu.addItem(makeItem("● 录屏中 — 结束并导出", action: #selector(stopRecording)))
            menu.addItem(makeItem("取消录屏", action: #selector(cancelRecording)))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("放大屏幕" + keySuffix(.zoom), action: #selector(triggerZoom)))
        menu.addItem(makeItem("画笔标注" + keySuffix(.draw), action: #selector(triggerDraw)))
        menu.addItem(makeItem("截图录屏" + keySuffix(.shot), action: #selector(triggerShot)))
        menu.addItem(.separator())

        let shelfCount = ShelfStore.shared.count
        let shelfTitle = (shelfCount > 0 ? "暂存板 · \(shelfCount)" : "暂存板") + keySuffix(.shelf)
        menu.addItem(makeItem(shelfTitle, action: #selector(triggerShelf)))
        menu.addItem(makeItem("粘贴到暂存板" + keySuffix(.shelfPaste), action: #selector(shelfPaste)))
        menu.addItem(.separator())

        let clipStore = ClipboardStore.shared
        let clipState = !ClipboardSettings.enabled ? " · 已关闭" : (clipStore.isPaused ? " · 已暂停" : "")
        menu.addItem(makeItem("剪贴板历史\(clipState)" + keySuffix(.clipboard), action: #selector(triggerClipboard)))
        let clipMenu = NSMenu()
        if ClipboardSettings.enabled {
            if clipStore.isPaused {
                clipMenu.addItem(makeItem("恢复记录", action: #selector(clipResume)))
            } else {
                let p15 = makeItem("暂停记录 15 分钟", action: #selector(clipPause(_:))); p15.tag = 15
                let p60 = makeItem("暂停记录 1 小时", action: #selector(clipPause(_:))); p60.tag = 60
                let pInf = makeItem("暂停记录，直到手动恢复", action: #selector(clipPause(_:))); pInf.tag = 0
                [p15, p60, pInf].forEach(clipMenu.addItem)
            }
        } else {
            clipMenu.addItem(makeItem("开启剪贴板历史", action: #selector(clipEnable)))
        }
        clipMenu.addItem(.separator())
        let c5 = makeItem("清除最近 5 分钟", action: #selector(clipClear(_:))); c5.tag = 5
        let c15 = makeItem("清除最近 15 分钟", action: #selector(clipClear(_:))); c15.tag = 15
        let cAll = makeItem("清除全部…", action: #selector(clipClear(_:))); cAll.tag = 0
        [c5, c15, cAll].forEach(clipMenu.addItem)
        let clipSub = NSMenuItem(title: "剪贴板记录", action: nil, keyEquivalent: "")
        clipSub.submenu = clipMenu
        menu.addItem(clipSub)
        menu.addItem(.separator())

        if DockSettings.switcherEnabled {
            menu.addItem(makeItem("窗口切换器" + keySuffix(.windowSwitcher), action: #selector(openSwitcher)))
        }
        let dockItem = makeItem("程序坞预览" + keySuffix(.dockPreview), action: #selector(toggleDockPreview))
        dockItem.state = DockSettings.previewEnabled ? .on : .off
        menu.addItem(dockItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("偏好设置…", action: #selector(openPrefs), keyEquivalent: ","))
        menu.addItem(makeItem("关于与使用说明", action: #selector(showAboutHelp)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func applyHotkeys() {
        // 解绑全部
        for (_, id) in hotkeyIDs { hotkeys.unregister(id: id) }
        hotkeyIDs.removeAll()

        for action in HotkeyAction.allCases {
            let b = HotkeyConfig.shared.binding(for: action)
            let handler: () -> Void
            switch action {
            case .zoom:  handler = { [weak self] in self?.triggerZoom() }
            case .draw:  handler = { [weak self] in self?.triggerDraw() }
            case .shot:  handler = { [weak self] in self?.triggerShot() }
            case .shelf: handler = { [weak self] in self?.triggerShelf() }
            case .shelfPaste: handler = { [weak self] in self?.shelfPaste() }
            case .clipboard: handler = { [weak self] in self?.triggerClipboard() }
            case .windowSwitcher: handler = { WindowSwitcherController.shared.hotkeyPressed() }
            case .dockPreview: handler = { DockPreviewController.shared.toggleEnabled() }
            }
            guard !b.isNone else { continue }
            if let id = hotkeys.register(keyCode: b.keyCode, modifiers: b.modifierFlags, handler: handler) {
                hotkeyIDs[action] = id
            }
        }
    }

    @objc private func onHotkeysChanged() {
        applyHotkeys()
        rebuildMenu()
    }

    @objc private func onShelfChanged() {
        rebuildMenu()
    }

    @objc private func triggerZoom() {
        guard !isRecordingBusy() else { return }
        if draw.isActive { draw.stop() }
        if shot.isActive { shot.stop() }
        zoom.toggle()
    }

    @objc private func triggerDraw() {
        guard !isRecordingBusy() else { return }
        if zoom.isActive { zoom.stop() }
        if shot.isActive { shot.stop() }
        draw.toggle()
    }

    @objc private func triggerShot() {
        // 录屏进行中：快捷键直接结束并导出
        if RecordingController.shared.isRecording {
            RecordingController.shared.stop()
            return
        }
        if zoom.isActive { zoom.stop() }
        if draw.isActive { draw.stop() }
        shot.toggle()
    }

    @objc private func triggerShelf() {
        ShelfController.shared.toggle()
    }

    @objc private func shelfPaste() {
        ShelfController.shared.addFromClipboard()
    }

    @objc private func openSwitcher() {
        WindowSwitcherController.shared.openSticky()
    }

    @objc private func toggleDockPreview() {
        DockPreviewController.shared.toggleEnabled()
    }

    @objc private func triggerClipboard() {
        ClipboardController.shared.toggle()
    }

    @objc private func clipPause(_ sender: NSMenuItem) {
        ClipboardStore.shared.pause(minutes: sender.tag > 0 ? sender.tag : nil)
        ScreenshotToast.show(sender.tag > 0 ? "已暂停记录剪贴板 \(sender.title.replacingOccurrences(of: "暂停记录 ", with: ""))"
                                            : "已暂停记录剪贴板，可在菜单中恢复")
    }

    @objc private func clipResume() {
        ClipboardStore.shared.resume()
        ScreenshotToast.show("已恢复记录剪贴板")
    }

    @objc private func clipEnable() {
        ClipboardSettings.enabled = true
        ScreenshotToast.show("已开启剪贴板历史")
    }

    @objc private func clipClear(_ sender: NSMenuItem) {
        if sender.tag > 0 {
            ClipboardStore.shared.clear(lastMinutes: sender.tag)
            ScreenshotToast.show("已清除最近 \(sender.tag) 分钟的记录")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清除全部剪贴板历史？"
        alert.informativeText = "固定的条目会保留。此操作无法撤销。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            ClipboardStore.shared.clear(lastMinutes: nil)
            ScreenshotToast.show("已清除剪贴板历史")
        }
    }

    @objc private func stopRecording() {
        RecordingController.shared.stop()
    }

    @objc private func cancelRecording() {
        RecordingController.shared.cancel()
    }

    /// 录屏时屏蔽放大/画笔，避免遮挡与状态冲突
    private func isRecordingBusy() -> Bool {
        guard RecordingController.shared.isRecording else { return false }
        ScreenshotToast.show("录屏进行中，请先结束录制")
        return true
    }

    @objc private func openPrefs() {
        PreferencesWindowController.shared.show()
    }

    @objc private func showAboutHelp() {
        AboutHelpWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension NSImage {
    /// 生成指定颜色的副本（用于菜单栏彩色状态图标、自绘工具栏图标）
    func tinted(with color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
