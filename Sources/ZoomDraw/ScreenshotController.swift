import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 截图控制器：冻结全屏画面 → 选区/标注 → 复制或保存（交互参考微信 / 企业微信）
final class ScreenshotController {
    private(set) var isActive = false
    private var windows: [ScreenshotWindow] = []

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        Task { @MainActor in
            do {
                // 所有屏幕同时冻结，支持多显示器
                var created: [ScreenshotWindow] = []
                for screen in NSScreen.screens {
                    let snapshot = try await ScreenCapture.captureScreen(screen)
                    let win = ScreenshotWindow(screen: screen, snapshot: snapshot) { _, _ in }
                    win.shotView.onFinish = { [weak self, weak win] image, finish in
                        guard let self = self, let win = win else { return }
                        self.finish(image: image, kind: finish,
                                    screen: screen, selection: win.shotView.selectionRect)
                    }
                    created.append(win)
                }
                self.windows = created
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
                self.isActive = false
                self.showPermissionAlert(error: error)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        isActive = false
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
