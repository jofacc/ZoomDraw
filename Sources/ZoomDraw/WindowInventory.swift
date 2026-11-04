import AppKit
import ApplicationServices

// MARK: - 设置

enum DockSettings {
    private static let d = UserDefaults.standard

    static let hoverDelayOptions: [Double] = [0.1, 0.2, 0.3, 0.5, 0.8]
    /// 缩略图宽度：小 / 中 / 大
    static let thumbWidths: [CGFloat] = [160, 220, 300]

    static func registerDefaults() {
        d.register(defaults: [
            "dock.previewEnabled": true,
            "dock.hoverDelay": 0.3,
            "dock.thumbSize": 1,
            "dock.showMinimized": true,
            "dock.showTitles": true,
            "dock.showOtherSpaces": true,
            "dock.ignoredApps": [String](),
            "switcher.enabled": true,
        ])
    }

    static var previewEnabled: Bool {
        get { d.bool(forKey: "dock.previewEnabled") }
        set {
            d.set(newValue, forKey: "dock.previewEnabled")
            NotificationCenter.default.post(name: .dockSettingsChanged, object: nil)
        }
    }
    static var hoverDelay: Double {
        get { max(0.05, d.double(forKey: "dock.hoverDelay")) }
        set { d.set(newValue, forKey: "dock.hoverDelay") }
    }
    static var thumbSize: Int {
        get { min(2, max(0, d.integer(forKey: "dock.thumbSize"))) }
        set { d.set(newValue, forKey: "dock.thumbSize") }
    }
    static var thumbWidth: CGFloat { thumbWidths[thumbSize] }
    static var showMinimized: Bool {
        get { d.bool(forKey: "dock.showMinimized") }
        set { d.set(newValue, forKey: "dock.showMinimized") }
    }
    static var showTitles: Bool {
        get { d.bool(forKey: "dock.showTitles") }
        set { d.set(newValue, forKey: "dock.showTitles") }
    }
    static var showOtherSpaces: Bool {
        get { d.bool(forKey: "dock.showOtherSpaces") }
        set { d.set(newValue, forKey: "dock.showOtherSpaces") }
    }
    static var ignoredApps: [String] {
        get { d.stringArray(forKey: "dock.ignoredApps") ?? [] }
        set { d.set(newValue, forKey: "dock.ignoredApps") }
    }
    static var switcherEnabled: Bool {
        get { d.bool(forKey: "switcher.enabled") }
        set {
            d.set(newValue, forKey: "switcher.enabled")
            NotificationCenter.default.post(name: .dockSettingsChanged, object: nil)
        }
    }

    /// 系统「台前调度」是否开启（开启时程序坞预览会与之冲突，自动停用）
    static var isStageManagerOn: Bool {
        let v = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        return (v as? Bool) ?? false
    }
}

extension Notification.Name {
    static let dockSettingsChanged = Notification.Name("ZoomDraw.dockSettingsChanged")
}

// MARK: - 窗口模型

struct WindowInfo {
    /// 系统窗口号；无法获取时为 0
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    var title: String
    /// 全局坐标（左上原点，与 CGWindow 一致）
    var frame: CGRect
    var isMinimized: Bool
    /// 是否在当前桌面上（未最小化、未隐藏）
    var isOnCurrentSpace: Bool
    var isAppHidden: Bool
    /// 辅助功能句柄；其他桌面上的窗口拿不到，为 nil
    let axElement: AXUIElement?
    /// 前后层级，数值越小越靠前；不在屏上的为 Int.max
    var zIndex: Int

    var uid: String { windowID != 0 ? "w\(windowID)" : "p\(pid)-\(title)-\(Int(frame.minX))-\(Int(frame.minY))" }
    var isOnOtherSpace: Bool { axElement == nil && !isOnCurrentSpace && !isMinimized }
    var displayTitle: String { title.isEmpty ? appName : title }
    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

// MARK: - 辅助功能工具

enum AX {
    static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { value(el, name) as? String }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (value(el, name) as? NSNumber)?.boolValue }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (value(el, name) as? [AXUIElement]) ?? []
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    /// AXUIElement → CGWindowID。系统未公开此函数，按名字动态查找；找不到时返回 nil，调用方会改用位置匹配
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(el, &id) == .success && id != 0 ? id : nil
    }

    /// 对单个应用的辅助功能调用设置较短超时，避免某个应用卡死时拖慢整体
    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }
}

// MARK: - 窗口枚举与操作

enum WindowInventory {
    struct CGWin {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
        let onScreen: Bool
        let order: Int
    }

    /// 系统中所有正常层级（layer 0）的窗口，按前后顺序排列
    static func cgWindows() -> [CGWin] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [CGWin] = []
        for (i, info) in list.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bd = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard frame.width >= 80, frame.height >= 50 else { continue }
            out.append(CGWin(id: id, pid: pid,
                             title: info[kCGWindowName as String] as? String ?? "",
                             frame: frame,
                             onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                             order: i))
        }
        return out
    }

    /// 某个应用的全部窗口：当前桌面 → 其他桌面 → 最小化
    static func windows(of app: NSRunningApplication, cg: [CGWin]? = nil,
                        includeMinimized: Bool, includeOtherSpaces: Bool) -> [WindowInfo] {
        let pid = app.processIdentifier
        let cgList = (cg ?? cgWindows()).filter { $0.pid == pid }
        let appName = app.localizedName ?? ""
        let hidden = app.isHidden
        var result: [WindowInfo] = []
        var used = Set<CGWindowID>()

        if AXIsProcessTrusted() {
            for ax in AX.elements(AX.app(pid), kAXWindowsAttribute) {
                let subrole = AX.string(ax, kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let minimized = AX.bool(ax, kAXMinimizedAttribute) ?? false
                if minimized && !includeMinimized { continue }
                let axFrame = AX.frame(ax)
                var cgw: CGWin?
                if let id = AX.windowID(ax) {
                    cgw = cgList.first { $0.id == id }
                } else if let f = axFrame {
                    cgw = cgList.first { !used.contains($0.id) && abs($0.frame.minX - f.minX) < 2
                        && abs($0.frame.minY - f.minY) < 2 && abs($0.frame.width - f.width) < 2 }
                }
                let frame = axFrame ?? cgw?.frame ?? .zero
                guard frame.width >= 80, frame.height >= 50 else { continue }
                if let c = cgw { used.insert(c.id) }
                let title = AX.string(ax, kAXTitleAttribute) ?? cgw?.title ?? ""
                let onScreen = cgw?.onScreen ?? false
                result.append(WindowInfo(windowID: cgw?.id ?? 0, pid: pid, appName: appName,
                                         title: title, frame: frame, isMinimized: minimized,
                                         isOnCurrentSpace: onScreen && !minimized, isAppHidden: hidden,
                                         axElement: ax,
                                         zIndex: onScreen ? (cgw?.order ?? Int.max) : Int.max))
            }
        }

        // 辅助功能只能看到当前桌面的窗口；其他桌面上的窗口从系统窗口列表补充（要求有标题、尺寸像正常窗口）
        if includeOtherSpaces {
            for c in cgList where !used.contains(c.id) && !c.onScreen && !hidden
                && !c.title.isEmpty && c.frame.width >= 150 && c.frame.height >= 100 {
                result.append(WindowInfo(windowID: c.id, pid: pid, appName: appName, title: c.title,
                                         frame: c.frame, isMinimized: false, isOnCurrentSpace: false,
                                         isAppHidden: false, axElement: nil, zIndex: Int.max))
            }
        }
        // 未授权辅助功能时，至少能列出当前桌面的窗口
        if !AXIsProcessTrusted() {
            for c in cgList where c.onScreen {
                result.append(WindowInfo(windowID: c.id, pid: pid, appName: appName, title: c.title,
                                         frame: c.frame, isMinimized: false, isOnCurrentSpace: true,
                                         isAppHidden: false, axElement: nil, zIndex: c.order))
            }
        }
        return sort(result)
    }

    /// 所有普通应用的窗口（窗口切换器用），最近使用的在前
    static func allWindows(includeMinimized: Bool, includeOtherSpaces: Bool) -> [WindowInfo] {
        let cg = cgWindows()
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me
        }
        var buckets = [[WindowInfo]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let w = windows(of: apps[i], cg: cg, includeMinimized: includeMinimized,
                            includeOtherSpaces: includeOtherSpaces)
            lock.lock(); buckets[i] = w; lock.unlock()
        }
        return sort(buckets.flatMap { $0 })
    }

    private static func sort(_ list: [WindowInfo]) -> [WindowInfo] {
        func rank(_ w: WindowInfo) -> Int {
            if w.isOnCurrentSpace { return 0 }
            if w.isAppHidden && !w.isMinimized { return 1 }
            if w.isOnOtherSpace { return 2 }
            return 3
        }
        return list.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if a.element.zIndex != b.element.zIndex { return a.element.zIndex < b.element.zIndex }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: 操作

    /// 切换到窗口。其他桌面上的窗口只能激活应用，由系统切到对应桌面
    static func focus(_ w: WindowInfo) {
        guard let app = w.app else { return }
        if app.isHidden { app.unhide() }
        if let ax = w.axElement, AXIsProcessTrusted() {
            if AX.bool(ax, kAXMinimizedAttribute) == true { AX.set(ax, kAXMinimizedAttribute, false) }
            AX.set(AX.app(w.pid), kAXFrontmostAttribute, true)
            AX.set(ax, kAXMainAttribute, true)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            activate(app)
            // 有的应用激活时会把自己的另一个窗口提到最前，稍后再提一次目标窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            }
        } else {
            activate(app)
        }
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate(from: NSRunningApplication.current, options: [])
            if !app.isActive { app.activate() }
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    static func close(_ w: WindowInfo) {
        guard let ax = w.axElement, let btn = AX.element(ax, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(btn, kAXPressAction as CFString)
    }

    static func toggleMinimize(_ w: WindowInfo) {
        guard let ax = w.axElement else { return }
        let cur = AX.bool(ax, kAXMinimizedAttribute) ?? false
        AX.set(ax, kAXMinimizedAttribute, !cur)
    }

    static func toggleFullScreen(_ w: WindowInfo) {
        guard let ax = w.axElement else { return }
        if AX.bool(ax, kAXMinimizedAttribute) == true { AX.set(ax, kAXMinimizedAttribute, false) }
        let cur = AX.bool(ax, "AXFullScreen") ?? false
        if !AX.set(ax, "AXFullScreen", !cur), let btn = AX.element(ax, kAXFullScreenButtonAttribute) {
            AXUIElementPerformAction(btn, kAXPressAction as CFString)
        }
        if !cur { focus(w) }
    }

    static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// CG 坐标（左上原点）→ Cocoa 坐标（左下原点）
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
