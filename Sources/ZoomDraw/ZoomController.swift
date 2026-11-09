import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕放大控制器：捕获屏幕快照后全屏显示并跟随鼠标缩放（参考 ZoomIt 的"冻结画面 + 跟随放大"模式）
///
/// 和截图一样用 session 编号防止「抓取期间被取消 → 抓完仍弹出没人管的遮罩」
final class ZoomController {
    private(set) var isActive = false
    private var session = 0
    private var window: ZoomWindow?
    private let escapeGuard: OverlayEscapeGuard

    private static let captureTimeout: TimeInterval = 8

    init(hotkeys: HotkeyManager) {
        escapeGuard = OverlayEscapeGuard(hotkeys: hotkeys)
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        guard let screen = NSScreen.main else { return }
        Self.closeOrphanWindows()
        session += 1
        let s = session
        isActive = true // 先标记，避免双触发

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout) { [weak self] in
            guard let self = self, self.session == s, self.isActive, self.window == nil else { return }
            NSLog("[ZoomDraw] 放大：抓取屏幕超时，已取消")
            self.stop()
            ScreenshotToast.show("放大启动超时，请再试一次", duration: 2)
        }

        Task { @MainActor in
            do {
                let snapshot = try await ScreenCapture.captureScreen(screen)
                guard self.session == s, self.isActive else { return }   // 期间已取消
                let win = ZoomWindow(screen: screen, snapshot: snapshot, onExit: { [weak self] in
                    self?.escapeGuard.press()
                })
                self.window = win
                // 放大模式下 Esc 本来就是直接退出，所以普通 Esc 和连按都等于 stop
                self.escapeGuard.arm(onEscape: { [weak self] in self?.stop() },
                                     onForceExit: { [weak self] in self?.stop() })
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard self.session == s else { return }
                self.stop()
                self.showPermissionAlert(error: error)
            }
        }
    }

    /// 任何状态下都清理干净
    func stop() {
        session += 1
        escapeGuard.disarm()
        window?.orderOut(nil)
        window = nil          // 不主动 close，避免触发 windowWillClose 连锁；ARC 自动释放
        isActive = false
        Self.closeOrphanWindows()
    }

    private static func closeOrphanWindows() {
        for w in NSApp.windows where w is ZoomWindow && w.isVisible { w.orderOut(nil) }
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
