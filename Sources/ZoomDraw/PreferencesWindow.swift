import AppKit

/// 偏好设置窗口：录制全局快捷键
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var rows: [HotkeyAction: HotkeyRecorderField] = [:]

    private convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "ZoomDraw 偏好设置"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        buildUI()
    }

    func show() {
        if let w = window {
            w.center()
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let actions = HotkeyAction.allCases
        let rowH: CGFloat = 36
        let topPad: CGFloat = 24
        let leftPad: CGFloat = 24

        // 标题
        let title = NSTextField(labelWithString: "全局快捷键")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: leftPad, y: content.bounds.height - topPad - 20, width: 200, height: 20)
        title.autoresizingMask = [.minYMargin]
        content.addSubview(title)

        let hint = NSTextField(labelWithString: "点击右侧输入框，按下你想要的组合键")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: leftPad, y: title.frame.minY - 18, width: 360, height: 16)
        hint.autoresizingMask = [.minYMargin]
        content.addSubview(hint)

        // 行
        for (i, action) in actions.enumerated() {
            let yTop = hint.frame.minY - 24 - CGFloat(i) * rowH

            let label = NSTextField(labelWithString: action.title)
            label.font = NSFont.systemFont(ofSize: 13)
            label.frame = NSRect(x: leftPad, y: yTop, width: 120, height: 22)
            label.autoresizingMask = [.minYMargin]
            content.addSubview(label)

            let recorder = HotkeyRecorderField(frame: NSRect(x: leftPad + 130, y: yTop - 4, width: 200, height: 28))
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
            content.addSubview(recorder)
            rows[action] = recorder
        }

        // 重置按钮
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: content.bounds.width - 24 - 100, y: 16, width: 100, height: 28)
        reset.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(reset)
    }

    private func findConflict(new: HotkeyBinding, except: HotkeyAction) -> HotkeyAction? {
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording ? NSColor.tertiaryLabelColor : NSColor.labelColor
        ]
        let s = (text as NSString)
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        // 仅允许常见修饰键
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
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
