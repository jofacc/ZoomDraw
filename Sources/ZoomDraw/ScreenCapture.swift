import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕捕获与窗口探测的共享工具
enum ScreenCapture {

    /// 抓取指定屏幕的全屏快照（真实像素尺寸）
    @MainActor
    static func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let dispID = displayID(of: screen)
        guard let scDisplay = content.displays.first(where: { $0.displayID == dispID }) ?? content.displays.first else {
            throw NSError(domain: "ZoomDraw", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(scDisplay.width) * screen.backingScaleFactor)
        cfg.height = Int(CGFloat(scDisplay.height) * screen.backingScaleFactor)
        cfg.showsCursor = false
        cfg.capturesAudio = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 当前屏幕上「肉眼可见」的窗口矩形（全局坐标，左下原点），按 z-order 从前到后排列。
    /// 仅保留正常层级、不透明、真正在屏上的窗口，用于「微信式」窗口自动吸附识别。
    static func visibleWindowRects(on screen: NSScreen) -> [NSRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }

        // CGWindow 使用「主屏左上」为原点的翻转坐标
        let flipBase = (NSScreen.screens.first?.frame.maxY) ?? 0
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // 这些进程的窗口是系统装饰层，不应作为截图目标
        let ignoredOwners: Set<String> = ["Window Server", "Dock", "Wallpaper", "壁纸",
                                          "Control Center", "控制中心", "Spotlight", "通知中心",
                                          "NotificationCenter", "TextInputMenuAgent", "Universal Control"]

        var rects: [NSRect] = []          // 结果：front → back
        var coveredArea: [NSRect] = []    // 位于更前方的窗口，用于判断是否被完全遮挡

        for info in list {
            // 1) 仅正常窗口层（0）与浮动面板层（1–3）；负值是桌面/壁纸，大值是菜单栏、Dock 等
            guard let layer = info[kCGWindowLayer as String] as? Int, (0...3).contains(layer) else { continue }
            // 2) 必须真正显示在屏幕上
            if let onscreen = info[kCGWindowIsOnscreen as String] as? Bool, !onscreen { continue }
            // 3) 透明窗口（很多 App 用它做阴影/占位）不参与
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.15 { continue }
            // 4) 排除自己的遮罩窗口
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == selfPID { continue }
            // 5) 排除系统装饰层
            if let owner = info[kCGWindowOwnerName as String] as? String, ignoredOwners.contains(owner) { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cg = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            // 6) 过小的窗口（提示条、阴影层）忽略
            if cg.width < 60 || cg.height < 40 { continue }

            let flipped = NSRect(x: cg.minX, y: flipBase - cg.maxY, width: cg.width, height: cg.height)
            guard flipped.intersects(screen.frame) else { continue }
            let visible = flipped.intersection(screen.frame)
            if visible.width < 60 || visible.height < 40 { continue }

            // 7) 被前方窗口完全覆盖 → 肉眼看不到，剔除
            if coveredArea.contains(where: { $0.contains(visible) }) {
                continue
            }
            coveredArea.append(visible)
            rects.append(visible)
        }
        return rects
    }
}
