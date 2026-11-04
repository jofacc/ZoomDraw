import AppKit
import ApplicationServices

/// 通过辅助功能接口监听程序坞：鼠标停在哪个图标上，程序坞会把它设为「选中」，这里把选中变化转发出来
final class DockWatcher {
    struct Item: Equatable {
        /// 正在运行的应用进程号；未运行或不是应用图标时为 nil
        let pid: pid_t?
        let bundleID: String?
        let title: String
        /// 图标位置（Cocoa 坐标，左下原点）
        let frame: NSRect
    }

    static let shared = DockWatcher()

    var onChange: ((Item?) -> Void)?
    private(set) var current: Item?
    var isRunning: Bool { observer != nil }

    private var observer: AXObserver?
    private var list: AXUIElement?
    private var retryTimer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        attach()
    }

    func stop() {
        started = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        retryTimer?.invalidate(); retryTimer = nil
        detach()
    }

    // MARK: 连接程序坞
    private func attach() {
        detach()
        guard started else { return }
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              setUp(pid: dock.processIdentifier) else {
            scheduleRetry()
            return
        }
        retryTimer?.invalidate(); retryTimer = nil
    }

    private func setUp(pid: pid_t) -> Bool {
        let dockEl = AXUIElementCreateApplication(pid)
        guard let list = AX.elements(dockEl, kAXChildrenAttribute)
                .first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }) else { return false }
        var obs: AXObserver?
        guard AXObserverCreate(pid, dockCallback, &obs) == .success, let obs = obs else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
                == .success else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        self.observer = obs
        self.list = list
        return true
    }

    private func detach() {
        if let obs = observer {
            if let list = list {
                AXObserverRemoveNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        list = nil
        if current != nil { current = nil; onChange?(nil) }
    }

    /// 未授权或程序坞还没起来时，每 3 秒重试
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.attach() }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    @objc private func appLaunched(_ n: Notification) {
        guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                == "com.apple.dock" else { return }
        // 程序坞重启（例如修改了设置）后需要重新挂接
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.attach() }
    }

    @objc private func appTerminated(_ n: Notification) {
        guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                == "com.apple.dock" else { return }
        detach()
        scheduleRetry()
    }

    // MARK: 选中变化
    fileprivate func selectionChanged() {
        let item = list.flatMap { AX.elements($0, kAXSelectedChildrenAttribute).first }.flatMap(Self.parse)
        guard item != current else { return }
        current = item
        onChange?(item)
    }

    private static func parse(_ el: AXUIElement) -> Item? {
        guard AX.string(el, kAXSubroleAttribute) == "AXApplicationDockItem",
              let f = AX.frame(el) else { return nil }
        let title = AX.string(el, kAXTitleAttribute) ?? ""
        let url = (AX.value(el, kAXURLAttribute) as? NSURL).map { $0 as URL }
        let running = AX.bool(el, "AXIsApplicationRunning") ?? false

        var app: NSRunningApplication?
        if running {
            let apps = NSWorkspace.shared.runningApplications
            if let url = url {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                app = apps.first { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path }
            }
            if app == nil { app = apps.first { $0.localizedName == title && $0.activationPolicy == .regular } }
        }
        let bundleID = app?.bundleIdentifier ?? url.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return Item(pid: app?.processIdentifier, bundleID: bundleID, title: title,
                    frame: WindowInventory.cocoaRect(f))
    }
}

private let dockCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon = refcon else { return }
    Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue().selectionChanged()
}
