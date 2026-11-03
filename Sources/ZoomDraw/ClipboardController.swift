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

    // MARK: 显示

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let s = ClipboardHistoryView.size
            panel.setFrame(NSRect(x: (vf.midX - s.width / 2).rounded(),
                                  y: (vf.midY - s.height / 2).rounded(),
                                  width: s.width, height: s.height), display: false)
        }
        historyView?.prepareForShow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(historyView?.searchField)
    }

    func hide() {
        panel?.orderOut(nil)
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
        hide()
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
