import AppKit

/// 偏好设置窗口：按模块分标签页（快捷键 / 暂存板 / 剪贴板 / 程序坞 / 网页搜索）
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var rows: [HotkeyAction: HotkeyRecorderField] = [:]

    private static let winSize = NSSize(width: 540, height: 540)

    private convenience init() {
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: PreferencesWindowController.winSize),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "ZoomDraw 偏好设置"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        buildUI()
    }

    func show() {
        if let w = window {
            if !w.isVisible { w.center() }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            // 不要让第一个快捷键输入框自动进入录制状态
            w.makeFirstResponder(nil)
        }
    }

    /// 打开并切换到指定标签页（hotkeys / shelf / clipboard / dock / websearch / ai）
    func show(tab: String) {
        tabView?.selectTabViewItem(withIdentifier: tab)
        show()
    }

    private var tabView: NSTabView?

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let tabs = NSTabView(frame: content.bounds.insetBy(dx: 12, dy: 12))
        tabs.autoresizingMask = [.width, .height]
        tabView = tabs

        let hotkeyItem = NSTabViewItem(identifier: "hotkeys")
        hotkeyItem.label = "快捷键"
        hotkeyItem.view = buildHotkeyPane(size: tabs.contentRect.size)
        tabs.addTabViewItem(hotkeyItem)

        let shelfItem = NSTabViewItem(identifier: "shelf")
        shelfItem.label = "暂存板"
        shelfItem.view = buildShelfPane(size: tabs.contentRect.size)
        tabs.addTabViewItem(shelfItem)

        let clipItem = NSTabViewItem(identifier: "clipboard")
        clipItem.label = "剪贴板"
        clipItem.view = ClipboardPrefsPane(frame: NSRect(origin: .zero, size: tabs.contentRect.size))
        tabs.addTabViewItem(clipItem)

        let dockItem = NSTabViewItem(identifier: "dock")
        dockItem.label = "程序坞"
        dockItem.view = DockPrefsPane(frame: NSRect(origin: .zero, size: tabs.contentRect.size))
        tabs.addTabViewItem(dockItem)

        let webItem = NSTabViewItem(identifier: "websearch")
        webItem.label = "快捷搜索"
        webItem.view = WebSearchPrefsPane(frame: NSRect(origin: .zero, size: tabs.contentRect.size))
        tabs.addTabViewItem(webItem)

        let aiItem = NSTabViewItem(identifier: "ai")
        aiItem.label = "AI"
        aiItem.view = AIPrefsPane(frame: NSRect(origin: .zero, size: tabs.contentRect.size))
        tabs.addTabViewItem(aiItem)

        content.addSubview(tabs)
    }

    // MARK: - 快捷键面板
    private func buildHotkeyPane(size: NSSize) -> NSView {
        let pane = NSView(frame: NSRect(origin: .zero, size: size))
        pane.autoresizingMask = [.width, .height]

        let leftPad: CGFloat = 20
        let rowH: CGFloat = 34

        let hint = NSTextField(labelWithString: "点击右侧输入框，按下你想要的组合键；录制时按 ⌫ 可清除（不设置）")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: leftPad, y: size.height - 30, width: size.width - leftPad * 2, height: 16)
        hint.autoresizingMask = [.minYMargin]
        pane.addSubview(hint)

        for (i, action) in HotkeyAction.allCases.enumerated() {
            let yTop = hint.frame.minY - 28 - CGFloat(i) * rowH

            let label = NSTextField(labelWithString: action.title)
            label.font = NSFont.systemFont(ofSize: 13)
            label.frame = NSRect(x: leftPad, y: yTop, width: 150, height: 22)
            label.autoresizingMask = [.minYMargin]
            pane.addSubview(label)

            let recorder = HotkeyRecorderField(frame: NSRect(x: leftPad + 160, y: yTop - 4,
                                                             width: 190, height: 28))
            recorder.action = action
            recorder.onChange = { [weak self] new in
                guard let self = self else { return }
                if let conflict = self.findConflict(new: new, except: action) {
                    let alert = NSAlert()
                    alert.messageText = "快捷键冲突"
                    alert.informativeText = "\(new.displayString) 已被「\(conflict.title)」占用。"
                    alert.runModal()
                    recorder.binding = HotkeyConfig.shared.binding(for: action) // 还原
                } else {
                    HotkeyConfig.shared.setBinding(new, for: action)
                }
            }
            recorder.binding = HotkeyConfig.shared.binding(for: action)
            recorder.autoresizingMask = [.minYMargin]
            pane.addSubview(recorder)
            rows[action] = recorder
        }

        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: size.width - 20 - 140, y: 14, width: 140, height: 28)
        reset.autoresizingMask = [.minXMargin, .maxYMargin]
        pane.addSubview(reset)

        return pane
    }

    // MARK: - 暂存板面板
    private func buildShelfPane(size: NSSize) -> NSView {
        let pane = NSView(frame: NSRect(origin: .zero, size: size))
        pane.autoresizingMask = [.width, .height]

        let leftPad: CGFloat = 20
        var y = size.height - 34

        func addCheckbox(_ title: String, _ hint: String, on: Bool, action: Selector) {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: action)
            cb.state = on ? .on : .off
            cb.frame = NSRect(x: leftPad, y: y, width: size.width - leftPad * 2, height: 20)
            cb.autoresizingMask = [.minYMargin]
            pane.addSubview(cb)

            let h = NSTextField(labelWithString: hint)
            h.font = NSFont.systemFont(ofSize: 11)
            h.textColor = .secondaryLabelColor
            h.frame = NSRect(x: leftPad + 18, y: y - 18, width: size.width - leftPad * 2 - 18, height: 16)
            h.autoresizingMask = [.minYMargin]
            pane.addSubview(h)

            y -= 48
        }

        addCheckbox("拖动文件时自动浮现",
                    "关闭后仅通过快捷键或菜单栏唤出",
                    on: ShelfController.autoShowOnDrag,
                    action: #selector(toggleAutoShow(_:)))

        addCheckbox("拖到屏幕边缘时自动收起",
                    "收起后点击露出的细条即可拉回",
                    on: ShelfController.edgeHideEnabled,
                    action: #selector(toggleEdgeHide(_:)))

        // 自动收回延时
        let label = NSTextField(labelWithString: "召唤后自动收回")
        label.font = NSFont.systemFont(ofSize: 13)
        label.frame = NSRect(x: leftPad, y: y, width: 130, height: 22)
        label.autoresizingMask = [.minYMargin]
        pane.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: leftPad + 140, y: y - 4, width: 140, height: 26),
                                  pullsDown: false)
        for sec in ShelfController.autoCollapseOptions {
            let title = sec <= 0 ? "不自动收回" : "\(Int(sec)) 秒后"
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = Int(sec)
        }
        popup.selectItem(withTag: Int(ShelfController.autoCollapseDelay))
        popup.target = self
        popup.action = #selector(changeAutoCollapse(_:))
        popup.autoresizingMask = [.minYMargin]
        pane.addSubview(popup)

        let delayHint = NSTextField(labelWithString: "仅在停靠于屏幕边缘时生效；鼠标停留在板子上不会收回")
        delayHint.font = NSFont.systemFont(ofSize: 11)
        delayHint.textColor = .secondaryLabelColor
        delayHint.frame = NSRect(x: leftPad, y: y - 24, width: size.width - leftPad * 2, height: 16)
        delayHint.autoresizingMask = [.minYMargin]
        pane.addSubview(delayHint)

        return pane
    }

    // MARK: - 动作
    @objc private func toggleAutoShow(_ sender: NSButton) {
        ShelfController.autoShowOnDrag = (sender.state == .on)
    }

    @objc private func toggleEdgeHide(_ sender: NSButton) {
        ShelfController.edgeHideEnabled = (sender.state == .on)
    }

    @objc private func changeAutoCollapse(_ sender: NSPopUpButton) {
        ShelfController.autoCollapseDelay = TimeInterval(sender.selectedTag())
    }

    private func findConflict(new: HotkeyBinding, except: HotkeyAction) -> HotkeyAction? {
        guard !new.isNone else { return nil }
        for a in HotkeyAction.allCases where a != except {
            if HotkeyConfig.shared.binding(for: a) == new { return a }
        }
        return nil
    }

    @objc private func resetAll() {
        HotkeyConfig.shared.resetAll()
        for (a, r) in rows { r.binding = HotkeyConfig.shared.binding(for: a) }
    }
}

/// 快捷键录制输入框
final class HotkeyRecorderField: NSView {
    var action: HotkeyAction = .zoom
    var binding: HotkeyBinding = HotkeyBinding(keyCode: 0, modifiers: 0) {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotkeyBinding) -> Void)?

    private var recording = false {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        recording = true; return true
    }
    override func resignFirstResponder() -> Bool {
        recording = false; return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.textBackgroundColor
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor

        let text = recording ? "请按下组合键…" : binding.displayString
        let dim = recording || binding.isNone
        let attrs: [NSAttributedString.Key: Any] = [
            .font: binding.isNone && !recording ? NSFont.systemFont(ofSize: 13)
                                                : NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor
        ]
        let s = (text as NSString)
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        // 仅允许常见修饰键
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // 不带修饰键按 ⌫ / ⌦：清除快捷键
        if mods.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            binding = .none
            onChange?(.none)
            window?.makeFirstResponder(nil)
            return
        }
        // 至少要一个修饰键，避免误触
        guard !mods.isEmpty else {
            NSSound.beep(); return
        }
        // ESC 取消录制
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil); return
        }
        let new = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue)
        binding = new
        onChange?(new)
        window?.makeFirstResponder(nil)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
