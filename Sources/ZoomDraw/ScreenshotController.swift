import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 截图控制器：冻结全屏画面 → 选区/标注 → 复制或保存（交互参考微信 / 企业微信）
///
/// 状态：idle → capturing（正在抓取屏幕，异步，可能要 0.2–2 秒）→ active（遮罩已显示）→ idle。
/// 每次开始都会生成新的 session 编号；抓取完成时如果 session 已变（期间被取消或重新开始），丢弃结果，
/// 不会出现「没人管的遮罩窗口」。
final class ScreenshotController {
    private enum State { case idle, capturing, active }
    private var state: State = .idle
    private var session = 0
    private var windows: [ScreenshotWindow] = []
    private let escapeGuard: OverlayEscapeGuard

    /// 抓取屏幕超过这个时间还没完成就放弃（避免一直卡在 capturing，之后快捷键都无效）
    private static let captureTimeout: TimeInterval = 8

    var isActive: Bool { state != .idle }

    init(hotkeys: HotkeyManager) {
        escapeGuard = OverlayEscapeGuard(hotkeys: hotkeys)
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .capturing:
            // 正在抓取时再按一次：取消这次截图（抓取结果会被丢弃）
            stop()
        case .active:
            // 遮罩应该在屏幕上；如果已经看不到了（异常情况），直接重新开始
            if windows.contains(where: \.isVisible) {
                stop()
            } else {
                stop()
                start()
            }
        }
    }

    func start() {
        guard state == .idle else { return }
        Self.closeOrphanWindows()
        session += 1
        let s = session
        state = .capturing

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout) { [weak self] in
            guard let self = self, self.session == s, self.state == .capturing else { return }
            NSLog("[ZoomDraw] 截图：抓取屏幕超时，已取消")
            self.stop()
            ScreenshotToast.show("截图启动超时，请再试一次", duration: 2)
        }

        Task { @MainActor in
            do {
                // 所有屏幕同时冻结，支持多显示器
                var created: [ScreenshotWindow] = []
                for screen in NSScreen.screens {
                    let snapshot = try await ScreenCapture.captureScreen(screen)
                    guard self.session == s else { return }   // 已取消
                    let win = ScreenshotWindow(screen: screen, snapshot: snapshot) { _, _ in }
                    win.shotView.onFinish = { [weak self, weak win] image, finish in
                        guard let self = self, let win = win, self.session == s else {
                            win?.orderOut(nil)   // 不属于当前会话的窗口：直接关掉
                            return
                        }
                        self.finish(image: image, kind: finish,
                                    screen: screen, selection: win.shotView.selectionRect)
                    }
                    win.shotView.onEscapeKey = { [weak self] in self?.escapeGuard.press() }
                    created.append(win)
                }
                guard self.session == s, self.state == .capturing else { return }
                self.windows = created
                self.state = .active
                self.escapeGuard.arm(onEscape: { [weak self] in self?.handleEscape() },
                                     onForceExit: { [weak self] in self?.forceExit() })
                for w in created { w.orderFrontRegardless() }
                NSApp.activate(ignoringOtherApps: true)
                // 鼠标所在屏幕的窗口设为 key，保证键盘事件
                let mouse = NSEvent.mouseLocation
                if let idx = NSScreen.screens.firstIndex(where: { $0.frame.contains(mouse) }),
                   idx < created.count {
                    created[idx].makeKeyAndOrderFront(nil)
                } else {
                    created.first?.makeKeyAndOrderFront(nil)
                }
            } catch {
                guard self.session == s else { return }
                self.stop()
                self.showPermissionAlert(error: error)
            }
        }
    }

    /// 结束截图：任何状态下都会清理干净（不再依赖 isActive 判断）
    func stop() {
        session += 1
        state = .idle
        escapeGuard.disarm()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        Self.closeOrphanWindows()
    }

    /// 普通 Esc：交给键盘焦点所在（或鼠标所在）屏幕的遮罩处理
    private func handleEscape() {
        guard state == .active, !windows.isEmpty else { stop(); return }
        let mouse = NSEvent.mouseLocation
        let target = windows.first(where: \.isKeyWindow)
            ?? windows.first(where: { $0.frame.contains(mouse) })
            ?? windows[0]
        target.shotView.handleEscape()
        // 遮罩失去焦点时顺便抢回来，后续按键能正常送达
        if state == .active, !target.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            target.makeKeyAndOrderFront(nil)
        }
    }

    /// 连按 Esc：无条件关闭
    private func forceExit() {
        stop()
        ScreenshotToast.show("已强制退出截图")
    }

    /// 兜底：关闭所有还显示着的截图遮罩（包括早期版本可能遗留的）
    private static func closeOrphanWindows() {
        for w in NSApp.windows where w is ScreenshotWindow && w.isVisible { w.orderOut(nil) }
    }

    // MARK: - 结束处理
    private func finish(image: NSImage?, kind: ScreenshotFinish,
                        screen: NSScreen, selection: NSRect) {
        switch kind {
        case .cancelled:
            stop()
        case .copied:
            stop()
            if let img = image {
                copyToPasteboard(img)
                ScreenshotToast.show("已复制到剪贴板")
            }
        case .saved:
            stop()
            if let img = image { saveToFile(img) }
        case .record:
            stop()
            // 等遮罩层彻底消失再开始采集，避免录进半透明遮罩
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                RecordingController.shared.start(screen: screen, localRect: selection)
            }
        }
    }

    /// 把截图写入剪贴板。
    ///
    /// 必须只产生**一个** NSPasteboardItem：同一张图的 PNG / TIFF 只是它的不同
    /// 表示形式（representation），应挂在同一个 item 上，由接收方按需挑选。
    /// 若分成多个 item（例如 `setData` 后再 `writeObjects`，后者会追加新 item），
    /// 支持多项粘贴的应用（Word、Pages、微信、备忘录等）会把每个 item 各粘贴一次，
    /// 导致一次 ⌘V 出现两张相同的图。
    private func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()

        let item = NSPasteboardItem()
        var wrote = false
        if let tiff = image.tiffRepresentation {
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
                wrote = true
            }
            // TIFF 作为兼容表示，供不识别 PNG 的老应用使用
            item.setData(tiff, forType: .tiff)
            wrote = true
        }
        guard wrote else { return }
        pb.writeObjects([item])
    }

    private func saveToFile(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截图 \(Self.timestamp()).png"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.title = "保存截图"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            ScreenshotToast.show("已保存到 \(url.lastPathComponent)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    private func showPermissionAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "屏幕捕获失败"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 ZoomDraw，然后重新启动应用。\n\n详细信息：\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 轻量结果提示（自动淡出）
enum ScreenshotToast {
    private static var window: NSWindow?

    static func show(_ text: String, duration: TimeInterval = 1.4) {
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let w = label.frame.width + 40
        let h = label.frame.height + 22
        guard let screen = NSScreen.main else { return }
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.frame.minY + screen.frame.height * 0.12,
                          width: w, height: h)

        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.88).cgColor
        container.layer?.cornerRadius = h / 2
        label.frame = NSRect(x: 20, y: (h - label.frame.height) / 2,
                             width: label.frame.width, height: label.frame.height)
        container.addSubview(label)
        win.contentView = container
        win.alphaValue = 0
        win.orderFrontRegardless()
        window = win

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            win.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
                if window === win { window = nil }
            })
        }
    }
}
