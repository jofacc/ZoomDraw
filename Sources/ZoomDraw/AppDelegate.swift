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
        ShelfController.shared.startup()
        ClipboardStore.shared.startup()
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

    private func rebuildMenu() {
        let zoomKey = HotkeyConfig.shared.binding(for: .zoom).displayString
        let drawKey = HotkeyConfig.shared.binding(for: .draw).displayString
        let shotKey = HotkeyConfig.shared.binding(for: .shot).displayString
        let shelfKey = HotkeyConfig.shared.binding(for: .shelf).displayString
        let pasteKey = HotkeyConfig.shared.binding(for: .shelfPaste).displayString

        let menu = NSMenu()
        if RecordingController.shared.isRecording {
            menu.addItem(makeItem("● 录屏中 — 结束并导出", action: #selector(stopRecording)))
            menu.addItem(makeItem("取消录屏", action: #selector(cancelRecording)))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("放大屏幕  (\(zoomKey))", action: #selector(triggerZoom)))
        menu.addItem(makeItem("画笔标注  (\(drawKey))", action: #selector(triggerDraw)))
        menu.addItem(makeItem("截图录屏  (\(shotKey))", action: #selector(triggerShot)))
        menu.addItem(.separator())

        let shelfCount = ShelfStore.shared.count
        let shelfTitle = shelfCount > 0 ? "暂存板 · \(shelfCount)  (\(shelfKey))"
                                        : "暂存板  (\(shelfKey))"
        menu.addItem(makeItem(shelfTitle, action: #selector(triggerShelf)))
        menu.addItem(makeItem("粘贴到暂存板  (\(pasteKey))", action: #selector(shelfPaste)))
        menu.addItem(.separator())

        let clipKey = HotkeyConfig.shared.binding(for: .clipboard).displayString
        let clipStore = ClipboardStore.shared
        let clipState = !ClipboardSettings.enabled ? " · 已关闭" : (clipStore.isPaused ? " · 已暂停" : "")
        menu.addItem(makeItem("剪贴板历史\(clipState)  (\(clipKey))", action: #selector(triggerClipboard)))
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
        menu.addItem(makeItem("偏好设置…", action: #selector(openPrefs), keyEquivalent: ","))
        menu.addItem(makeItem("使用说明", action: #selector(showHelp)))
        menu.addItem(makeItem("关于 ZoomDraw", action: #selector(showAbout)))
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
            }
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

    @objc private func showHelp() {
        let zoomKey = HotkeyConfig.shared.binding(for: .zoom).displayString
        let drawKey = HotkeyConfig.shared.binding(for: .draw).displayString
        let shotKey = HotkeyConfig.shared.binding(for: .shot).displayString
        let shelfKey = HotkeyConfig.shared.binding(for: .shelf).displayString
        let alert = NSAlert()
        alert.messageText = "ZoomDraw 使用说明"
        alert.informativeText = """
        全局快捷键（可在「偏好设置」中修改）：
          \(zoomKey)  开/关 放大模式
          \(drawKey)  开/关 画笔标注模式
          \(shotKey)  截图 / 录屏
          \(shelfKey)  开/关 暂存板
          \(HotkeyConfig.shared.binding(for: .shelfPaste).displayString)  剪贴板内容存入暂存板
          \(HotkeyConfig.shared.binding(for: .clipboard).displayString)  开/关 剪贴板历史

        放大模式：
          • 鼠标移动：跟随焦点
          • 滚轮 / + - ：调节倍率（1× – 8×）
          • 鼠标左键单击：暂停画面（自动启用画笔）
          • ESC：退出

        放大暂停后（自动进入画笔叠加）：
          • H 或 Tab：隐藏/显示画笔
          • 1/2/3/4/5：红/黄/绿/蓝/白  ·  [ / ]：笔触
          • A 自由 · B 矩形 · C 椭圆 · D 箭头
          • Z 撤销  ·  X 清空当前画面  ·  ESC 退出

        截图：
          • 拖动框选；单击可自动选中鼠标下最上层的窗口
          • 放大镜实时取色，显示坐标与 HEX
          • 选区确定后拖动控制点微调，拖内部整体移动
          • 双击选区内部：立即完成并复制到剪贴板
          • 工具栏：矩形 B · 椭圆 C · 箭头 D · 画笔 A · 马赛克 M · 文字 T
          • 1-6 切换颜色；[ / ] 调整粗细；⌘Z 撤销
          • ⏎ 或 ⌘C 完成并复制  ·  ⌘S 保存 PNG
          • ⌘A 全屏  ·  右键返回重新框选  ·  ESC 退出

        录屏（选好区域后点工具栏红色圆点，或按 ⌘R）：
          • 录制区域显示红色虚线边框，附带悬浮控制条
          • 控制条：暂停/继续（Space）· 结束并导出（⏎）· 取消（ESC）
          • 结束后可导出为 MP4 视频或 GIF 动图
          • 录屏中再次按截图快捷键 = 立即结束并导出

        暂存板（跨应用搬运文件的中转站）：
          • 把文件拖入暂存板，再从暂存板拖到目标应用
          • 也支持拖入/粘贴文本、图片、网址（自动落盘成文件）
          • 拖动文件时会自动浮现（可在偏好设置中关闭）
          • 窗口拖到屏幕左/右/上边缘松手即自动收起，只留一条彩色细条
          • 点击细条（或按暂存板快捷键）即可拉回；拖着文件靠近也会自动探出
          • 停靠状态下召唤出来，鼠标离开后按设定秒数自动收回（偏好设置可调）
          • 单击即可直接拖拽，无需先激活窗口
          • 空白处按住拖动 = 拉框多选（按 ⌘/⇧ 追加选择）
          • 双击打开 · Delete 移除 · ⌘A 全选 · ⌘C 复制 · ⌘V 粘贴
          • 右键：在 Finder 中显示 / 清理失效条目 / 清空
          • 拖动标题栏可移动窗口，右下角可调整大小

        剪贴板历史（自动记录复制过的文本、链接、颜色、图片、文件）：
          • 打开后直接输入即可搜索；Tab / ⇧Tab 切换分类
          • ⏎ 粘贴到当前应用 · ⇧⏎ 以纯文本粘贴 · ⌘1–9 直接粘贴第 N 条
          • ⌘C 仅复制 · ⌘P 固定 · ⌘⌫ 删除 · ⌘S 存入暂存板 · ⌘O 打开
          • 条目可直接拖到其他应用
          • 自动粘贴需要「辅助功能」权限；密码管理器的内容不会被记录
          • 菜单栏「剪贴板记录」可暂停记录或清除最近记录

        独立画笔标注：
          • 鼠标拖拽绘制；同样的 1-5 / A/B/C/D / Z / X / ESC

        提示：首次使用「放大 / 截图 / 录屏」需在系统设置中授予「屏幕录制」权限。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let alert = NSAlert()
        alert.messageText = "ZoomDraw  v\(short) (build \(build))"
        alert.informativeText = "一个轻量的屏幕放大、截图、录屏、标注、文件暂存与剪贴板历史工具\n\n版权所有 tywinliu，保留所有权利。"
        alert.runModal()
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
