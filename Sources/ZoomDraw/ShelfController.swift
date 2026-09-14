import AppKit

/// 暂存板控制器：显示/隐藏、位置记忆、拖拽自动唤出、贴边收起与自动回收
final class ShelfController {
    static let shared = ShelfController()

    /// 贴边收起后露出的可见宽度（点击这条即可拉回）
    static let peek: CGFloat = 8
    /// 判定「贴边」的距离阈值
    private static let snapThreshold: CGFloat = 24
    /// 收起状态下，拖着文件靠近多近才探出来接收
    private static let dragHotZone: CGFloat = 48

    enum Edge { case left, right, top }

    private var window: ShelfWindow?
    private var dragMonitor: Any?
    private var dragUpMonitor: Any?

    /// 是否由「拖拽自动唤出」显示（这种情况下拖拽结束后会自动隐藏）
    private var autoShown = false
    private var mouseInside = false
    private var hideWorkItem: DispatchWorkItem?

    /// 停靠边「记忆」：只要贴过边就记住，即使当前是展开状态也保留，
    /// 用于「召唤出来后没操作就自动收回」
    private var dockedEdge: Edge?
    /// 当前实际收起在哪条边；nil 表示展开
    private(set) var collapsedEdge: Edge?
    /// 停靠后完整可见的位置（展开时还原到这里）
    private var snappedFrame: NSRect?
    private var isAnimatingEdge = false
    private var collapseWorkItem: DispatchWorkItem?

    /// 当前是否处于一次「真实的内容拖拽会话」
    /// 拖拽面板在会话结束后仍残留类型数据，若不做会话判定，
    /// 任何鼠标拖动（拖窗口、拖选文字）都会误触发自动唤出
    private var activeDragSession = false
    private var lastSeenDragChangeCount = NSPasteboard(name: .drag).changeCount

    private let frameKey = "shelf.windowFrame"
    private static let autoShowKey = "shelf.autoShowOnDrag"
    private static let edgeHideKey = "shelf.edgeHide"
    private static let autoCollapseDelayKey = "shelf.autoCollapseDelay"

    /// 偏好：拖拽文件时自动唤出暂存板
    static var autoShowOnDrag: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoShowKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoShowKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoShowKey)
            shared.refreshDragMonitor()
        }
    }

    /// 偏好：拖到屏幕边缘时自动收起
    static var edgeHideEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: edgeHideKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: edgeHideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: edgeHideKey)
            if !newValue {
                shared.expand(animated: true)
                shared.dockedEdge = nil
                shared.cancelAutoCollapse()
            }
        }
    }

    /// 偏好：召唤出来后多少秒无操作自动收回；0 = 不自动收回
    static var autoCollapseDelay: TimeInterval {
        get {
            if UserDefaults.standard.object(forKey: autoCollapseDelayKey) == nil { return 3 }
            return UserDefaults.standard.double(forKey: autoCollapseDelayKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCollapseDelayKey)
            shared.scheduleAutoCollapse()
        }
    }

    /// 可选的自动收回延时（秒），0 表示关闭
    static let autoCollapseOptions: [TimeInterval] = [0, 1, 2, 3, 5, 10]

    var isVisible: Bool { window?.isVisible == true }
    var isCollapsed: Bool { collapsedEdge != nil }
    /// 是否停靠在某条边（含展开中的停靠状态）
    var isDocked: Bool { dockedEdge != nil }

    private init() {}

    func startup() {
        refreshDragMonitor()
    }

    // MARK: - 显示 / 隐藏
    func toggle() {
        guard isVisible, !autoShown else { show(auto: false); return }

        // 已收起 → 展开（展开后会按设置自动回收）
        if isCollapsed {
            expand(animated: true)
            focusWindow()
            return
        }
        // 兜底：万一窗口停在抓不到的位置，快捷键用来把它拉回来
        if let w = window, !w.isReachable {
            ensureReachable(w)
            focusWindow()
            return
        }
        // 展开中且处于停靠状态 → 快捷键收回到边上，而不是整个隐藏
        if let e = dockedEdge {
            collapseToDock(e)
            return
        }
        hide()
    }

    func show(auto: Bool) {
        cancelScheduledHide()
        let win = ensureWindow()
        // 手动唤出后就不再受「拖拽结束自动隐藏」管辖
        autoShown = isVisible ? (autoShown && auto) : auto
        win.shelfView.reload()
        win.orderFrontRegardless()
        if isCollapsed {
            expand(animated: true)      // 内部会安排自动回收
        } else {
            ensureReachable(win)
            scheduleAutoCollapse()      // 停靠状态下召唤出来也要能自动收回
        }
        if !auto { focusWindow() }
    }

    private func focusWindow() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func hide() {
        saveFrame()
        window?.orderOut(nil)
        autoShown = false
        cancelScheduledHide()
        cancelAutoCollapse()
    }

    private func ensureWindow() -> ShelfWindow {
        if let w = window { return w }
        let w = ShelfWindow(frame: defaultFrame())
        w.shelfView.onClose = { [weak self] in self?.hide() }
        w.shelfView.onHoverChange = { [weak self] inside in
            guard let self = self else { return }
            self.mouseInside = inside
            if inside {
                // 鼠标在板子上说明正在用，暂停一切自动收起
                self.cancelScheduledHide()
                self.cancelAutoCollapse()
            } else {
                self.scheduleAutoCollapse()
            }
        }
        // 点击露出的细条 → 拉回
        w.shelfView.onExpandRequest = { [weak self] in
            self?.expand(animated: true)
            self?.focusWindow()
        }
        // 用户手动拖动窗口结束 → 立即判断是否贴边
        w.shelfView.onWindowDragEnded = { [weak self] in
            self?.handleWindowDragEnded()
        }
        // 拖动过程中不做自动收起判断
        w.shelfView.onWindowDragging = { [weak self] in
            self?.cancelAutoCollapse()
        }
        window = w
        return w
    }

    private func defaultFrame() -> NSRect {
        if let s = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(s)
            if r.width >= 240, r.height >= 180,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                // 无条件夹回可见区域：修复旧版本可能存下的屏外坐标
                return ShelfWindow.reachableFrame(r)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 300, height: 320)
        let vf = screen.visibleFrame
        return NSRect(x: vf.maxX - size.width - 24,
                      y: vf.maxY - size.height - 24,
                      width: size.width, height: size.height)
    }

    private func saveFrame() {
        guard let w = window, w.isVisible else { return }
        // 收起状态下保存展开后的位置，并夹回可见区域，避免下次启动窗口停在屏外
        let frame = ShelfWindow.reachableFrame(snappedFrame ?? w.frame)
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }

    /// 兜底自救：窗口若因任何原因停在抓不到的位置，显示时强制拉回屏内
    private func ensureReachable(_ w: ShelfWindow) {
        guard !isCollapsed, !w.isReachable else { return }
        w.allowsOffscreen = false
        w.setFrame(ShelfWindow.reachableFrame(w.frame), display: true)
    }

    // MARK: - 贴边收起
    /// 用户拖动窗口结束时调用：此刻鼠标已松开、窗口位置已确定，判断是否贴边
    private func handleWindowDragEnded() {
        guard let w = window, w.isVisible, !isCollapsed, !isAnimatingEdge else { return }
        guard Self.edgeHideEnabled else { dockedEdge = nil; return }

        let frame = w.frame
        guard let screen = screenFor(frame) else { return }
        // 统一用 visibleFrame：避开菜单栏与 Dock，保证收起后的细条一定可点
        let vf = screen.visibleFrame

        // 取距离最近的那条边（同时接近两条边时不会误判）
        let candidates: [(Edge, CGFloat)] = [
            (.left,  frame.minX - vf.minX),
            (.right, vf.maxX - frame.maxX),
            (.top,   vf.maxY - frame.maxY)
        ]
        guard let best = candidates.filter({ abs($0.1) <= Self.snapThreshold })
                .min(by: { abs($0.1) < abs($1.1) }) else {
            // 拖离边缘 → 解除停靠，不再自动收回
            dockedEdge = nil
            snappedFrame = nil
            cancelAutoCollapse()
            return
        }
        dockedEdge = best.0
        collapse(to: best.0, on: screen, from: frame)
    }

    /// 与屏幕重叠面积最大的那块屏
    private func screenFor(_ frame: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(frame)
            let area = i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        return best ?? NSScreen.main
    }

    /// 收回到已记忆的停靠边
    private func collapseToDock(_ edge: Edge) {
        guard let w = window, w.isVisible, !isCollapsed, !isAnimatingEdge else { return }
        guard let screen = screenFor(w.frame) else { return }
        collapse(to: edge, on: screen, from: w.frame)
    }

    private func collapse(to edge: Edge, on screen: NSScreen, from frame: NSRect) {
        cancelAutoCollapse()
        let vf = screen.visibleFrame

        // 先算出「紧贴边缘且完整可见」的位置，作为展开时的还原目标
        var full = frame
        switch edge {
        case .left:  full.origin.x = vf.minX
        case .right: full.origin.x = vf.maxX - full.width
        case .top:   full.origin.y = vf.maxY - full.height
        }
        snappedFrame = full

        // 再算出收起后的位置：主体移出可见区域，只留 peek 宽度
        var target = full
        switch edge {
        case .left:  target.origin.x = vf.minX - full.width + Self.peek
        case .right: target.origin.x = vf.maxX - Self.peek
        case .top:   target.origin.y = vf.maxY - Self.peek
        }

        dockedEdge = edge
        collapsedEdge = edge
        window?.shelfView.collapsedEdge = edge
        window?.hasShadow = false   // 收起后大半在屏外，阴影会溢到屏幕上
        setFrame(target, animated: true)
    }

    /// 展开（点击细条 / 快捷键 / 拖文件靠近时调用）
    func expand(animated: Bool) {
        guard let w = window, collapsedEdge != nil else { return }
        // 还原目标兜底夹一次，防止屏幕分辨率变化后还原到屏外
        let target = ShelfWindow.reachableFrame(snappedFrame ?? w.frame)
        collapsedEdge = nil
        w.shelfView.collapsedEdge = nil
        w.hasShadow = true
        setFrame(target, animated: animated)
    }

    private func setFrame(_ rect: NSRect, animated: Bool) {
        guard let w = window else { return }
        isAnimatingEdge = true
        // 只有程序化的收起/展开才允许越过屏幕边界
        w.allowsOffscreen = true
        let unlock: () -> Void = { [weak self] in
            guard let self = self, let w = self.window else { return }
            self.isAnimatingEdge = false
            // 收起状态需要保持越界许可，展开后立刻恢复约束
            w.allowsOffscreen = self.isCollapsed
            // 窗口是「滑到鼠标下面」的，AppKit 不会补发 mouseEntered/Exited，
            // 这里按鼠标实际位置纠正一次，否则自动收回会误判
            self.syncMouseInside()
            if !self.isCollapsed { self.scheduleAutoCollapse() }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(rect, display: true)
            }, completionHandler: unlock)
        } else {
            w.setFrame(rect, display: true)
            unlock()
        }
    }

    /// 依据鼠标真实位置校正 mouseInside
    private func syncMouseInside() {
        guard let w = window, w.isVisible else { mouseInside = false; return }
        mouseInside = w.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - 自动收回
    /// 处于停靠状态、当前展开、鼠标不在板子上 → 延时后收回
    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        guard Self.edgeHideEnabled, Self.autoCollapseDelay > 0,
              let edge = dockedEdge, isVisible, !isCollapsed, !mouseInside else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.mouseInside, self.isVisible, !self.isCollapsed,
                  self.dockedEdge != nil else { return }
            // 正在拖拽内容时不收，避免把接收目标收走
            if self.activeDragSession {
                self.scheduleAutoCollapse()
                return
            }
            self.collapseToDock(edge)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay, execute: work)
    }

    private func cancelAutoCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    // MARK: - 拖拽自动唤出
    private func refreshDragMonitor() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let m = dragUpMonitor { NSEvent.removeMonitor(m); dragUpMonitor = nil }
        guard Self.autoShowOnDrag else { return }

        // 鼠标事件的全局监听无需辅助功能权限
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.handleGlobalDrag()
        }
        dragUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleGlobalDragEnd()
        }
    }

    private func handleGlobalDrag() {
        guard Self.autoShowOnDrag else { return }
        updateDragSessionState()
        guard activeDragSession else { return }

        if isCollapsed {
            // 收起状态：只有鼠标真的靠近停靠边才探出，避免在屏幕另一侧操作时乱弹
            guard let e = collapsedEdge, isMouseNearDock(e) else { return }
            expand(animated: true)
            return
        }
        if !isVisible { show(auto: true) }
    }

    /// 判定当前是否为「新的一次内容拖拽」
    /// 关键：拖拽面板的 changeCount 只在新会话开始时递增；
    /// 仅靠 types 判断会把「拖窗口 / 拖选文字」也当成文件拖拽（此前的误弹出 bug）
    private func updateDragSessionState() {
        let pb = NSPasteboard(name: .drag)
        let count = pb.changeCount
        guard count != lastSeenDragChangeCount else { return }
        lastSeenDragChangeCount = count
        let interesting: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .png, .tiff, .pdf, .string]
        activeDragSession = (pb.types ?? []).contains { interesting.contains($0) }
    }

    /// 鼠标是否已经靠近收起的那条边
    private func isMouseNearDock(_ edge: Edge) -> Bool {
        guard let w = window else { return false }
        let f = w.frame
        let m = NSEvent.mouseLocation
        let z = Self.dragHotZone
        switch edge {
        case .left:
            return m.x <= f.maxX + z && m.y >= f.minY && m.y <= f.maxY
        case .right:
            return m.x >= f.minX - z && m.y >= f.minY && m.y <= f.maxY
        case .top:
            return m.y >= f.minY - z && m.x >= f.minX && m.x <= f.maxX
        }
    }

    private func handleGlobalDragEnd() {
        activeDragSession = false
        if autoShown, isVisible {
            // 拖拽结束后，若鼠标不在暂存板上则自动隐藏
            scheduleHide(after: 1.6)
        } else {
            scheduleAutoCollapse()
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelScheduledHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.autoShown, !self.mouseInside else { return }
            self.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - 外部入口
    /// 把剪贴板内容加入暂存板（菜单项 / 快捷键用）
    func addFromClipboard() {
        let n = ShelfStore.shared.ingest(from: .general)
        if n > 0 {
            // 已显示就不强抢焦点，避免打断当前输入
            show(auto: !isVisible)
            ScreenshotToast.show("已加入暂存板 · \(n) 项")
        } else {
            ScreenshotToast.show("剪贴板中没有可暂存的内容")
        }
    }
}
