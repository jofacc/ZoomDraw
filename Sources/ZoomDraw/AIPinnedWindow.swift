import AppKit

/// AI 回答的复制 / 存入暂存板 / 打开链接
enum AIOutput {
    static func answerMarkdown(_ c: AIConversation?) -> String { c?.record.lastAnswer ?? "" }
    static func answerPlain(_ c: AIConversation?) -> String { MarkdownRenderer.plainText(answerMarkdown(c)) }

    /// 写入剪贴板（会记录到剪贴板历史）
    @discardableResult
    static func copy(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        return true
    }

    static func saveToShelf(_ c: AIConversation?) {
        let md = answerMarkdown(c)
        guard !md.isEmpty else { NSSound.beep(); return }
        ScreenshotToast.show(ShelfStore.shared.addText(md) ? "已存入暂存板" : "未能存入暂存板")
    }

    static func open(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https", let bid = WebSearch.browserBundleID,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 接收按键的浮窗
final class KeyHandlingPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let h = keyHandler, h(event) { return }
        super.sendEvent(event)
    }
}

/// 钉住的 AI 回答：独立的置顶窗口，可以继续追问
final class AIPinnedWindowController: NSObject, NSWindowDelegate {
    private static var openWindows: [AIPinnedWindowController] = []

    private let panel: KeyHandlingPanel
    private let resultView: AIResultView
    private let input = NSTextField()
    private let conversation: AIConversation

    static func pin(_ c: AIConversation, near frame: NSRect?) {
        let w = AIPinnedWindowController(conversation: c, near: frame)
        openWindows.append(w)
        w.panel.makeKeyAndOrderFront(nil)
        w.panel.makeFirstResponder(w.input)
    }

    private init(conversation c: AIConversation, near frame: NSRect?) {
        conversation = c
        let size = NSSize(width: 600, height: 680)
        panel = KeyHandlingPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        resultView = AIResultView(frame: NSRect(x: 0, y: 52, width: size.width, height: size.height - 52 - 28))
        super.init()

        panel.title = c.record.title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        resultView.autoresizingMask = [.width, .height]
        bg.addSubview(resultView)

        let sep = NSView(frame: NSRect(x: 0, y: 52, width: size.width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        sep.autoresizingMask = [.width]
        bg.addSubview(sep)

        input.frame = NSRect(x: 14, y: 22, width: size.width - 28, height: 24)
        input.placeholderString = "继续追问…  ⏎ 发送"
        input.font = NSFont.systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.autoresizingMask = [.width]
        bg.addSubview(input)

        let hint = NSTextField(labelWithString: "⏎ 追问    ⌘C 复制回答    ⇧⌘C 复制 Markdown    ⌘R 重新生成    ⌘S 存入暂存板    Esc 停止 / 关闭")
        hint.font = NSFont.systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 16, y: 4, width: size.width - 32, height: 14)
        hint.autoresizingMask = [.width]
        bg.addSubview(hint)

        resultView.onOpenURL = { AIOutput.open($0) }
        resultView.onCopyText = { s in AIOutput.copy(s); ScreenshotToast.show("已复制") }
        resultView.onAction = { [weak self] a in self?.perform(a) }
        resultView.attach(c)

        if let f = frame {
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height),
                           display: false)
            if let vf = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame {
                var r = panel.frame
                r.origin.y = max(vf.minY + 10, min(r.origin.y, vf.maxY - r.height))
                r.origin.x = max(vf.minX + 10, min(r.origin.x, vf.maxX - r.width - 10))
                panel.setFrame(r, display: false)
            }
        } else {
            panel.center()
        }
        panel.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
    }

    private func perform(_ action: String) {
        switch action {
        case "copy": if AIOutput.copy(AIOutput.answerPlain(conversation)) { ScreenshotToast.show("已复制回答") }
        case "copymd": if AIOutput.copy(AIOutput.answerMarkdown(conversation)) { ScreenshotToast.show("已复制 Markdown") }
        case "retry": conversation.regenerate()
        case "shelf": AIOutput.saveToShelf(conversation)
        case "settings": PreferencesWindowController.shared.show(tab: "ai")
        default: break
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let editor = input.currentEditor() as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let typed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e.keyCode {
        case 53:
            if conversation.isRunning { conversation.stop() } else { panel.close() }
            return true
        case 36, 76:
            guard !typed.isEmpty else { return true }
            conversation.ask(typed)
            input.stringValue = ""
            return true
        case 126 where typed.isEmpty && mods.isEmpty: resultView.scroll(by: -80); return true
        case 125 where typed.isEmpty && mods.isEmpty: resultView.scroll(by: 80); return true
        case 116: resultView.page(-1); return true
        case 121: resultView.page(1); return true
        default: break
        }
        guard mods.contains(.command) else { return false }
        switch e.keyCode {
        case 8: // ⌘C
            if let ed = editor, ed.selectedRange().length > 0 { ed.copy(nil); return true }
            let md = mods.contains(.shift)
            resultView.selectedText { [weak self] sel in
                guard let self = self else { return }
                if !sel.isEmpty && !md { AIOutput.copy(sel); ScreenshotToast.show("已复制选中内容"); return }
                let s = md ? AIOutput.answerMarkdown(self.conversation) : AIOutput.answerPlain(self.conversation)
                if AIOutput.copy(s) { ScreenshotToast.show(md ? "已复制 Markdown" : "已复制回答") } else { NSSound.beep() }
            }
            return true
        case 15 where mods == [.command]: conversation.regenerate(); return true   // ⌘R
        case 1 where mods == [.command]: AIOutput.saveToShelf(conversation); return true // ⌘S
        case 13: panel.close(); return true                                         // ⌘W
        case 0: editor?.selectAll(nil); return true
        case 9: editor?.paste(nil); return true
        case 7: editor?.cut(nil); return true
        case 6: editor?.undoManager?.undo(); return true
        case 126: resultView.scrollToEdge(top: true); return true
        case 125: resultView.scrollToEdge(top: false); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        conversation.stop()
        resultView.attach(nil)
        Self.openWindows.removeAll { $0 === self }
    }
}
