import AppKit
import Carbon.HIToolbox

/// 全屏遮罩（截图 / 放大 / 画笔）的退出保护：
/// - 遮罩显示期间把 Esc 注册为全局快捷键：即使遮罩窗口失去键盘焦点（被其他应用抢走），Esc 也一定能送到 ZoomDraw
/// - 1.5 秒内连按 3 次 Esc：不管当前处于什么状态，强制关闭遮罩
final class OverlayEscapeGuard {
    private let hotkeys: HotkeyManager
    private var hotkeyID: UInt32?
    private var presses: [Date] = []
    private var lastPress = Date.distantPast
    private var onEscape: (() -> Void)?
    private var onForceExit: (() -> Void)?

    static let forceCount = 3
    static let forceWindow: TimeInterval = 1.5

    init(hotkeys: HotkeyManager) {
        self.hotkeys = hotkeys
    }

    var isArmed: Bool { onForceExit != nil }

    /// onEscape：普通 Esc（交给遮罩按原有逻辑处理）；onForceExit：连按 3 次时强制关闭
    func arm(onEscape: @escaping () -> Void, onForceExit: @escaping () -> Void) {
        disarm()
        self.onEscape = onEscape
        self.onForceExit = onForceExit
        presses = []
        hotkeyID = hotkeys.register(keyCode: UInt32(kVK_Escape), modifiers: []) { [weak self] in self?.press() }
    }

    func disarm() {
        if let id = hotkeyID { hotkeys.unregister(id: id) }
        hotkeyID = nil
        onEscape = nil
        onForceExit = nil
        presses = []
    }

    /// 所有 Esc（全局快捷键、遮罩窗口自身收到的按键）都走这里；同一次按键可能从两条路径到达，60ms 内去重
    func press() {
        let now = Date()
        guard now.timeIntervalSince(lastPress) > 0.06 else { return }
        lastPress = now
        presses = presses.filter { now.timeIntervalSince($0) < Self.forceWindow } + [now]
        if presses.count >= Self.forceCount, let force = onForceExit {
            presses = []
            NSLog("[ZoomDraw] 连按 Esc，强制退出遮罩")
            force()
            return
        }
        onEscape?()
    }
}
