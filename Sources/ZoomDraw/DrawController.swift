import AppKit

final class DrawController {
    private(set) var isActive = false
    private var window: DrawWindow?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        guard let screen = NSScreen.main else { return }
        let win = DrawWindow(screen: screen, onExit: { [weak self] in
            self?.stop()
        })
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        window?.orderOut(nil)
        window = nil
        isActive = false
    }
}
