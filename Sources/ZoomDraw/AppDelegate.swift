import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let zoom = ZoomController()
    private let draw = DrawController()
    private let hotkeys = HotkeyManager()
    private var hotkeyIDs: [HotkeyAction: UInt32] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        applyHotkeys()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onHotkeysChanged),
            name: .hotkeysChanged, object: nil)
    }

    /// 关键：关闭最后一个窗口不要退出 app（菜单栏应用必须）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            // 用荧光笔图标，与"屏幕放大+标注"工具语义贴合，且菜单栏不易混淆
            let img = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "ZoomDraw")
                ?? NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "ZoomDraw")
            if let img = img {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "✎"
            }
        }
        statusItem.isVisible = true

        rebuildMenu()
    }

    private func rebuildMenu() {
        let zoomKey = HotkeyConfig.shared.binding(for: .zoom).displayString
        let drawKey = HotkeyConfig.shared.binding(for: .draw).displayString

        let menu = NSMenu()
        menu.addItem(makeItem("放大屏幕  (\(zoomKey))", action: #selector(triggerZoom)))
        menu.addItem(makeItem("画笔标注  (\(drawKey))", action: #selector(triggerDraw)))
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
            case .zoom: handler = { [weak self] in self?.triggerZoom() }
            case .draw: handler = { [weak self] in self?.triggerDraw() }
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

    @objc private func triggerZoom() {
        if draw.isActive { draw.stop() }
        zoom.toggle()
    }

    @objc private func triggerDraw() {
        if zoom.isActive { zoom.stop() }
        draw.toggle()
    }

    @objc private func openPrefs() {
        PreferencesWindowController.shared.show()
    }

    @objc private func showHelp() {
        let zoomKey = HotkeyConfig.shared.binding(for: .zoom).displayString
        let drawKey = HotkeyConfig.shared.binding(for: .draw).displayString
        let alert = NSAlert()
        alert.messageText = "ZoomDraw 使用说明"
        alert.informativeText = """
        全局快捷键（可在「偏好设置」中修改）：
          \(zoomKey)  开/关 放大模式
          \(drawKey)  开/关 画笔标注模式

        放大模式：
          • 鼠标移动：跟随焦点
          • 滚轮 / + - ：调节倍率（1× – 8×）
          • 鼠标左键单击：暂停画面（自动启用画笔）
          • ESC：退出

        放大暂停后（自动进入画笔叠加）：
          • H 或 Tab：隐藏/显示画笔
          • 鼠标拖拽：绘制
          • 1/2/3/4/5：红/黄/绿/蓝/白
          • [ / ]：调小/调大笔触
          • R 矩形 · O 椭圆 · A 箭头 · P 自由
          • Z 撤销  ·  C 清空当前画面
          • ESC 退出（画笔同步退出）

        独立画笔标注：
          • 鼠标拖拽绘制；同样的 1-5 / R/O/A/P / Z / C / ESC

        提示：首次使用「放大」需在系统设置中授予「屏幕录制」权限。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "ZoomDraw  v1.0"
        alert.informativeText = "一个轻量的屏幕放大与画笔标注工具\n\n版权所有 tywinliu，保留所有权利。"
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
