import AppKit

final class DrawController {
    private(set) var isActive = false
    private var window: DrawWindow?
    private let escapeGuard: OverlayEscapeGuard

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
        let win = DrawWindow(screen: screen, onExit: { [weak self] in
            self?.escapeGuard.press()
        })
        self.window = win
        // 全局 Esc：画笔遮罩失去键盘焦点时 Esc 也能退出
        escapeGuard.arm(onEscape: { [weak self] in self?.stop() },
                        onForceExit: { [weak self] in self?.stop() })
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isActive = true
    }

    func stop() {
        escapeGuard.disarm()
        window?.orderOut(nil)
        window = nil
        isActive = false
        Self.closeOrphanWindows()
    }

    private static func closeOrphanWindows() {
        for w in NSApp.windows where w is DrawWindow && w.isVisible { w.orderOut(nil) }
    }
}
