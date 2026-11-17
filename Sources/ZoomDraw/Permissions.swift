import AppKit
import ApplicationServices

/// 系统权限的统一入口：每次只出现一个界面，授权后自动提示，不再叠多层提示框
///
/// - 第一次请求：只触发系统自带的授权提示（它自带「打开系统设置」按钮），不再同时打开系统设置
/// - 之后再请求：直接打开系统设置对应页面，不弹任何提示框
/// - 授权成功后在屏幕上提示一次
enum Permissions {
    private static let d = UserDefaults.standard

    // MARK: 辅助功能

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        if d.bool(forKey: "perm.axRequested") {
            openSettings("Privacy_Accessibility")
        } else {
            d.set(true, forKey: "perm.axRequested")
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        watch(label: "辅助功能", granted: { AXIsProcessTrusted() })
    }

    // MARK: 屏幕录制

    static func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        if d.bool(forKey: "perm.srRequested") {
            openSettings("Privacy_ScreenCapture")
        } else {
            d.set(true, forKey: "perm.srRequested")
            _ = CGRequestScreenCaptureAccess()
        }
        // 屏幕录制授权后需要重启应用才生效，不轮询
    }

    /// 直接打开「隐私与安全性」中的某一页
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 授权后提示

    private static var watcher: Timer?

    /// 授权通常要等用户在系统设置里勾选：每秒检查一次，勾上后提示并刷新各设置页（最多 3 分钟）
    private static func watch(label: String, granted: @escaping () -> Bool) {
        watcher?.invalidate()
        let deadline = Date().addingTimeInterval(180)
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if granted() {
                t.invalidate()
                watcher = nil
                ScreenshotToast.show("\(label)已授权")
                NotificationCenter.default.post(name: .permissionsChanged, object: nil)
            } else if Date() > deadline {
                t.invalidate()
                watcher = nil
            }
        }
    }
}

extension Notification.Name {
    static let permissionsChanged = Notification.Name("ZoomDraw.permissionsChanged")
}
