import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕放大控制器：捕获屏幕快照后全屏显示并跟随鼠标缩放（参考 ZoomIt 的"冻结画面 + 跟随放大"模式）
final class ZoomController {
    private(set) var isActive = false
    private var window: ZoomWindow?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        guard let screen = NSScreen.main else { return }
        isActive = true // 先标记，避免双触发

        Task { @MainActor in
            do {
                let snapshot = try await ScreenCapture.captureScreen(screen)
                let win = ZoomWindow(screen: screen, snapshot: snapshot, onExit: { [weak self] in
                    self?.stop()
                })
                self.window = win
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                self.isActive = false
                self.showPermissionAlert(error: error)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        window?.orderOut(nil)
        window = nil          // 不主动 close，避免触发 windowWillClose 连锁；ARC 自动释放
        isActive = false
    }

    private func showPermissionAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "屏幕捕获失败"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 ZoomDraw，然后重新启动应用。\n\n详细信息：\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
