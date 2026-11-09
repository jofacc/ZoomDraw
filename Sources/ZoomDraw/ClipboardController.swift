import AppKit
import ApplicationServices

/// 剪贴板历史：面板显示 / 隐藏、粘贴回前台应用、辅助功能权限
final class ClipboardController: NSObject, NSWindowDelegate {
    static let shared = ClipboardController()

    private var panel: ClipboardPanel?
    private var historyView: ClipboardHistoryView?
    /// 打开面板前的前台应用（粘贴目标）
    private var targetApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }

    /// 面板显示 / 隐藏时通知（打开期间暂停其他全局快捷键，让 ⌘1–9 等按键交给面板）
    var onVisibilityChanged: ((Bool) -> Void)?

    // MARK: 显示

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        let resume = historyView?.canResumeAI == true && hiddenAt.map { Date().timeIntervalSince($0) < 120 } == true
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp = front
        } else if !resume {
            targetApp = nil
        }

        let panel = self.panel ?? makePanel()
        if resume { historyView?.prepareForResume() } else { historyView?.prepareForShow() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let s = ClipboardHistoryView.size
            let h = historyView?.isAIMode == true ? aiHeight(in: vf) : s.height
            let listTop = (vf.midY + s.height / 2).rounded()
            panel.setFrame(NSRect(x: (vf.midX - s.width / 2).rounded(), y: max(vf.minY + 10, listTop - h),
                                  width: s.width, height: h), display: false)
        }
        onVisibilityChanged?(true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(historyView?.searchField)
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        hiddenAt = Date()
        onVisibilityChanged?(false)
    }

    private var hiddenAt: Date?

    private func aiHeight(in vf: NSRect) -> CGFloat {
        min(ClipboardHistoryView.aiHeight, vf.height - 40).rounded()
    }

    /// 列表 ↔ AI 回答：保持顶部位置不变，调整高度
    private func resizePanel(ai: Bool) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(p.frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let h = ai ? aiHeight(in: vf) : ClipboardHistoryView.size.height
        var f = p.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = max(vf.minY + 10, top - h)
        p.setFrame(f, display: true)
    }

    private func makePanel() -> ClipboardPanel {
        let p = ClipboardPanel(size: ClipboardHistoryView.size)
        let v = ClipboardHistoryView(frame: NSRect(origin: .zero, size: ClipboardHistoryView.size))
        p.contentView = v
        p.delegate = self
        p.keyHandler = { [weak v] e in v?.handleKey(e) ?? false }

        v.onClose = { [weak self] in self?.hide() }
        v.onActivate = { [weak self] item, plain in self?.paste(item, plainText: plain) }
        v.onCopyOnly = { [weak self] item in self?.copyOnly(item) }
        v.onSaveToShelf = { [weak self] item in self?.saveToShelf(item) }
        v.onOpen = { [weak self] item in self?.open(item) }
        v.onWebSearch = { [weak self] engine, query in
            self?.hide()
            if !WebSearch.open(engine, query: query) { ScreenshotToast.show("「\(engine.name)」的网址模板无效") }
        }
        v.onModeChanged = { [weak self] ai in self?.resizePanel(ai: ai) }
        v.onPasteText = { [weak self] text in
            guard AIOutput.copy(text) else { return }
            self?.pasteCurrentPasteboard()
        }
        v.onPin = { [weak self] c in
            let frame = self?.panel?.frame
            self?.hide()
            AIPinnedWindowController.pin(c, near: frame)
        }
        v.onOpenAISettings = { [weak self] in
            self?.hide()
            PreferencesWindowController.shared.show(tab: "ai")
        }
        v.onOpenURL = { [weak self] url in
            self?.hide()
            AIOutput.open(url)
        }

        panel = p
        historyView = v
        return p
    }

    /// 点到面板外面就收起
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: 动作

    private func paste(_ item: ClipItem, plainText: Bool) {
        guard ClipboardStore.shared.writeToPasteboard(item, plainText: plainText) else {
            ScreenshotToast.show(item.kind == .file ? "文件已不存在" : "该条目已失效")
            return
        }
        pasteCurrentPasteboard()
    }

    /// 关闭面板，回到原来的应用并模拟 ⌘V（未开启自动粘贴时只提示已复制）
    private func pasteCurrentPasteboard() {
        hide()
        hiddenAt = nil   // 粘贴后再打开面板不再回到 AI 回答

        guard ClipboardSettings.autoPaste else {
            ScreenshotToast.show("已复制")
            return
        }
        guard AXIsProcessTrusted() else {
            ScreenshotToast.show("已复制，按 ⌘V 粘贴（开启辅助功能权限后可自动粘贴）", duration: 2.4)
            promptAccessibilityOnce()
            return
        }
        if let app = targetApp, !app.isActive {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.postCommandV() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.postCommandV() }
        }
    }

    private func copyOnly(_ item: ClipItem) {
        guard ClipboardStore.shared.writeToPasteboard(item, plainText: false) else {
            ScreenshotToast.show("该条目已失效")
            return
        }
        hide()
        ScreenshotToast.show("已复制")
    }

    private func saveToShelf(_ item: ClipItem) {
        let store = ClipboardStore.shared
        let shelf = ShelfStore.shared
        var ok = false
        switch item.kind {
        case .text, .color:
            ok = shelf.addText(store.fullText(of: item))
        case .link:
            if let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                ok = shelf.addLink(url)
            }
        case .image:
            if let img = NSImage(contentsOf: store.imageURL(item.id)) {
                ok = shelf.addImage(img)
            }
        case .file:
            ok = shelf.addFiles(item.existingFileURLs) > 0
        }
        ScreenshotToast.show(ok ? "已存入暂存板" : "未能存入（内容已失效或已在暂存板中）")
    }

    private func open(_ item: ClipItem) {
        let ws = NSWorkspace.shared
        switch item.kind {
        case .link:
            if let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) { ws.open(url) }
        case .file:
            let urls = item.existingFileURLs
            guard !urls.isEmpty else { ScreenshotToast.show("文件已不存在"); return }
            urls.forEach { ws.open($0) }
        case .image:
            if let url = Self.exportImage(item) { ws.open(url) }
        case .text, .color:
            if let url = Self.exportText(item) { ws.open(url) }
        }
        hide()
    }

    // MARK: 导出（拖出 / 打开时生成可读文件名的临时文件）

    private static var exportDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomDrawClipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let exportNameFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f
    }()

    static func exportImage(_ item: ClipItem) -> URL? {
        let src = ClipboardStore.shared.imageURL(item.id)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let dst = exportDir.appendingPathComponent("剪贴板图片 \(exportNameFormatter.string(from: item.createdAt)).png")
        if !FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        return FileManager.default.fileExists(atPath: dst.path) ? dst : nil
    }

    static func exportText(_ item: ClipItem) -> URL? {
        let dst = exportDir.appendingPathComponent("剪贴板文本 \(exportNameFormatter.string(from: item.createdAt)).txt")
        let text = ClipboardStore.shared.fullText(of: item)
        return (try? text.write(to: dst, atomically: true, encoding: .utf8)) != nil ? dst : nil
    }

    // MARK: 模拟 ⌘V

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    // MARK: 辅助功能权限

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示，并打开「隐私与安全性 → 辅助功能」
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptAccessibilityOnce() {
        let key = "clipboard.axPrompted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Self.requestAccessibility()
    }
}
