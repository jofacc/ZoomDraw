import AppKit
import ApplicationServices

/// 一项权限的当前状态
enum PermissionStatus: Equatable {
    case granted                // 已授权
    case missing                // 未授权，会影响功能
    case optionalMissing        // 未授权，但属于可选
    case warning(String)        // 有限制（例如剪贴板「每次询问」）
    case restartNeeded          // 已授权，需要重启应用才生效
    case notNeeded(String)      // 当前系统无需授权

    /// 计入「已就绪」
    var isReady: Bool {
        switch self {
        case .granted, .notNeeded: return true
        default: return false
        }
    }
}

struct PermissionInfo {
    enum ID { case accessibility, screenRecording, automation, pasteboard, fullDisk }
    let id: ID
    let title: String
    let symbol: String
    let features: String        // 哪些功能需要它
    let impact: String          // 没授权会怎样
    var status: PermissionStatus
    var isOptional: Bool { id == .fullDisk }
}

/// 系统权限的统一入口：每次只出现一个界面，授权后自动提示，不再叠多层提示框
///
/// - 第一次请求：只触发系统自带的授权提示（它自带「打开系统设置」按钮），不再同时打开系统设置
/// - 之后再请求：直接打开系统设置对应页面，不弹任何提示框
/// - 授权成功后在屏幕上提示一次
enum Permissions {
    private static let d = UserDefaults.standard

    // MARK: 总览（偏好设置 →「权限」页使用）

    /// 启动时屏幕录制是否已授权：授权是在运行中完成的话，要重启后才真正生效
    private static var screenAtLaunch = false
    static func noteLaunchState() { screenAtLaunch = CGPreflightScreenCaptureAccess() }

    /// 读取全部权限状态（自动化 / 完全磁盘访问的检测放在后台线程，回调在主线程）
    static func snapshot(_ completion: @escaping ([PermissionInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let automation = automationStatus(ask: false) == noErr
            let fullDisk = fullDiskAccessGranted
            DispatchQueue.main.async { completion(items(automation: automation, fullDisk: fullDisk)) }
        }
    }

    private static func items(automation: Bool, fullDisk: Bool) -> [PermissionInfo] {
        var screen: PermissionStatus = .missing
        if CGPreflightScreenCaptureAccess() { screen = screenAtLaunch ? .granted : .restartNeeded }

        var pasteboard: PermissionStatus = .notNeeded("当前系统无需授权")
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysDeny: pasteboard = .missing
            case .ask: pasteboard = .warning("每次读取都会询问")
            default: pasteboard = .granted
            }
        }

        return [
            PermissionInfo(id: .accessibility, title: "辅助功能", symbol: "accessibility",
                           features: "选中后自动粘贴（剪贴板历史、文件搜索的 AI 回答）· 程序坞窗口预览 · 窗口切换器（切换 / 关闭 / 最小化窗口）",
                           impact: "只复制，需要手动按 ⌘V；程序坞预览与窗口切换器无法使用",
                           status: AXIsProcessTrusted() ? .granted : .missing),
            PermissionInfo(id: .screenRecording, title: "屏幕录制", symbol: "record.circle",
                           features: "放大模式 · 截图 · 录屏 · 程序坞预览与窗口切换器里的窗口画面（授权后需要重启 ZoomDraw）",
                           impact: "放大、截图、录屏无法捕获屏幕；窗口预览只显示应用图标",
                           status: screen),
            PermissionInfo(id: .automation, title: "自动化（控制访达）", symbol: "gearshape.2",
                           features: "文件搜索操作菜单里的「显示简介」",
                           impact: "只有「显示简介」不能用，改为在访达中显示文件",
                           status: automation ? .granted : .missing),
            PermissionInfo(id: .pasteboard, title: "剪贴板访问", symbol: "doc.on.clipboard",
                           features: "剪贴板历史读取你复制的内容（仅 macOS 15.4 及以上有此权限项）",
                           impact: "剪贴板历史无法记录新复制的内容",
                           status: pasteboard),
            PermissionInfo(id: .fullDisk, title: "完全磁盘访问（可选）", symbol: "externaldrive",
                           features: "文件搜索读取桌面 / 文稿 / 下载等受保护的文件夹时，系统不再逐个弹窗询问",
                           impact: "访问受保护的文件夹时，系统会逐个询问，不影响使用",
                           status: fullDisk ? .granted : .optionalMissing),
        ]
    }

    /// 点击某一行的按钮
    static func perform(_ info: PermissionInfo) {
        switch info.id {
        case .accessibility:
            requestAccessibility()
        case .screenRecording:
            if info.status == .restartNeeded { relaunch() } else { requestScreenRecording() }
        case .automation:
            requestAutomation()
        case .pasteboard:
            openPasteboardSettings()
        case .fullDisk:
            openSettings("Privacy_AllFiles")
            watch(label: "完全磁盘访问", granted: { fullDiskAccessGranted })
        }
    }

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
        // 授权后要重启才生效；勾选后刷新「权限」页，提示重启
        watch(label: "屏幕录制", granted: { CGPreflightScreenCaptureAccess() })
    }

    /// 重新启动 ZoomDraw
    static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: 自动化（控制访达）

    /// ask 为 true 时，首次会弹出系统授权提示并等待用户选择（会阻塞，请放在后台线程）
    private static func automationStatus(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
    }

    static func requestAutomation() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = automationStatus(ask: true)
            DispatchQueue.main.async {
                if r == noErr {
                    ScreenshotToast.show("自动化已授权")
                    NotificationCenter.default.post(name: .permissionsChanged, object: nil)
                } else {
                    // 之前拒绝过，系统不会再弹提示，只能去系统设置里勾选
                    openSettings("Privacy_Automation")
                    watch(label: "自动化", granted: { automationStatus(ask: false) == noErr })
                }
            }
        }
    }

    // MARK: 剪贴板 / 完全磁盘访问

    static func openPasteboardSettings() {
        for s in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 没有完全磁盘访问权限时，读取系统的 TCC 数据库会被拒绝
    static var fullDiskAccessGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    // MARK: 系统设置

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
