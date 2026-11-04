import AppKit
import UniformTypeIdentifiers

/// 偏好设置 →「程序坞」标签页：程序坞预览 + 窗口切换器
final class DockPrefsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "去授权…", target: nil, action: nil)
    private let srStatus = NSTextField(labelWithString: "")
    private let srButton = NSButton(title: "去授权…", target: nil, action: nil)
    private let stageNote = NSTextField(labelWithString: "")
    private let switcherHint = NSTextField(labelWithString: "")
    private let ignoreTable = NSTableView()
    private var ignored: [String] = DockSettings.ignoredApps
    private var keyObserver: NSObjectProtocol?
    private var hotkeyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        build()
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .hotkeysChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshStatus() }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        [keyObserver, hotkeyObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        guard let w = window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.refreshStatus()
            }
        refreshStatus()
    }

    // MARK: 构建
    private func build() {
        let W = bounds.width
        let pad: CGFloat = 20
        var y = bounds.height - 30

        func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 13,
                   secondary: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = NSFont.systemFont(ofSize: size)
            if secondary { l.textColor = .secondaryLabelColor }
            l.frame = NSRect(x: x, y: y, width: w, height: size + 5)
            l.lineBreakMode = .byTruncatingTail
            l.autoresizingMask = [.minYMargin]
            addSubview(l)
            return l
        }
        func checkbox(_ s: String, on: Bool, x: CGFloat, y: CGFloat, w: CGFloat, action: Selector) {
            let b = NSButton(checkboxWithTitle: s, target: self, action: action)
            b.state = on ? .on : .off
            b.frame = NSRect(x: x, y: y, width: w, height: 20)
            b.autoresizingMask = [.minYMargin]
            addSubview(b)
        }
        func popup(x: CGFloat, y: CGFloat, w: CGFloat, items: [(String, Int)], selected: Int, action: Selector) {
            let p = NSPopUpButton(frame: NSRect(x: x, y: y - 4, width: w, height: 26), pullsDown: false)
            for (t, tag) in items { p.addItem(withTitle: t); p.lastItem?.tag = tag }
            p.selectItem(withTag: selected)
            p.target = self
            p.action = action
            p.autoresizingMask = [.minYMargin]
            addSubview(p)
        }

        // 1. 程序坞预览
        checkbox("启用程序坞预览", on: DockSettings.previewEnabled, x: pad, y: y, w: 300,
                 action: #selector(togglePreview(_:)))
        _ = label("鼠标停在程序坞图标上时，显示该应用所有窗口的缩略图，点击即可切换",
                  x: pad + 18, y: y - 18, w: W - pad * 2 - 18, size: 11, secondary: true)
        y -= 46

        _ = label("悬停延迟", x: pad, y: y, w: 70)
        popup(x: pad + 72, y: y, w: 100,
              items: DockSettings.hoverDelayOptions.map { (String(format: "%.1f 秒", $0), Int($0 * 1000)) },
              selected: Int(DockSettings.hoverDelay * 1000), action: #selector(changeDelay(_:)))
        _ = label("缩略图大小", x: pad + 200, y: y, w: 80)
        popup(x: pad + 282, y: y, w: 90, items: [("小", 0), ("中", 1), ("大", 2)],
              selected: DockSettings.thumbSize, action: #selector(changeSize(_:)))
        y -= 34

        checkbox("显示最小化的窗口", on: DockSettings.showMinimized, x: pad, y: y, w: 150,
                 action: #selector(toggleMinimized(_:)))
        checkbox("显示其他桌面的窗口", on: DockSettings.showOtherSpaces, x: pad + 150, y: y, w: 160,
                 action: #selector(toggleOtherSpaces(_:)))
        checkbox("显示窗口标题", on: DockSettings.showTitles, x: pad + 314, y: y, w: 130,
                 action: #selector(toggleTitles(_:)))
        y -= 20
        _ = label("其他桌面上的窗口点击后会切到对应应用；以上三项对窗口切换器同样生效",
                  x: pad + 2, y: y, w: W - pad * 2, size: 11, secondary: true)
        y -= 34

        // 2. 窗口切换器
        checkbox("启用窗口切换器", on: DockSettings.switcherEnabled, x: pad, y: y, w: 300,
                 action: #selector(toggleSwitcher(_:)))
        switcherHint.font = NSFont.systemFont(ofSize: 11)
        switcherHint.textColor = .secondaryLabelColor
        switcherHint.maximumNumberOfLines = 2
        switcherHint.cell?.wraps = true
        switcherHint.frame = NSRect(x: pad + 18, y: y - 34, width: W - pad * 2 - 18, height: 32)
        switcherHint.autoresizingMask = [.minYMargin]
        addSubview(switcherHint)
        y -= 62

        // 3. 不显示预览的应用
        _ = label("不显示程序坞预览的应用", x: pad, y: y, w: W - pad * 2)
        let listH: CGFloat = 78
        y -= listH + 6
        let scroll = NSScrollView(frame: NSRect(x: pad, y: y, width: W - pad * 2 - 64, height: listH))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.minYMargin, .width]
        let col = NSTableColumn(identifier: .init("app"))
        col.width = scroll.contentSize.width
        ignoreTable.addTableColumn(col)
        ignoreTable.headerView = nil
        ignoreTable.rowHeight = 22
        ignoreTable.dataSource = self
        ignoreTable.delegate = self
        scroll.documentView = ignoreTable
        addSubview(scroll)

        let add = NSButton(title: "添加…", target: self, action: #selector(addIgnoredApp))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.frame = NSRect(x: W - pad - 58, y: y + listH - 24, width: 58, height: 24)
        add.autoresizingMask = [.minYMargin, .minXMargin]
        addSubview(add)
        let del = NSButton(title: "移除", target: self, action: #selector(removeIgnoredApp))
        del.bezelStyle = .rounded
        del.controlSize = .small
        del.frame = NSRect(x: W - pad - 58, y: y + listH - 52, width: 58, height: 24)
        del.autoresizingMask = [.minYMargin, .minXMargin]
        addSubview(del)
        y -= 32

        // 4. 权限
        for (status, button, action, row) in [(axStatus, axButton, #selector(requestAX), 0),
                                              (srStatus, srButton, #selector(requestSR), 1)] {
            let ry = y - CGFloat(row) * 26
            status.font = NSFont.systemFont(ofSize: 11)
            status.frame = NSRect(x: pad, y: ry, width: 340, height: 16)
            status.autoresizingMask = [.minYMargin]
            addSubview(status)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.frame = NSRect(x: pad + 350, y: ry - 4, width: 90, height: 24)
            button.autoresizingMask = [.minYMargin]
            addSubview(button)
        }

        stageNote.font = NSFont.systemFont(ofSize: 11)
        stageNote.textColor = .systemOrange
        stageNote.frame = NSRect(x: pad, y: 12, width: W - pad * 2, height: 16)
        stageNote.autoresizingMask = [.maxYMargin, .width]
        addSubview(stageNote)
    }

    private func refreshStatus() {
        if AXIsProcessTrusted() {
            axStatus.stringValue = "✓ 辅助功能：已授权（识别程序坞图标、切换 / 关闭窗口）"
            axStatus.textColor = .systemGreen
            axButton.isHidden = true
        } else {
            axStatus.stringValue = "✗ 辅助功能：未授权，程序坞预览无法工作"
            axStatus.textColor = .systemOrange
            axButton.isHidden = false
        }
        if WindowThumbnailer.hasScreenRecordingPermission {
            srStatus.stringValue = "✓ 屏幕录制：已授权（显示窗口画面）"
            srStatus.textColor = .systemGreen
            srButton.isHidden = true
        } else {
            srStatus.stringValue = "✗ 屏幕录制：未授权，缩略图只显示应用图标"
            srStatus.textColor = .systemOrange
            srButton.isHidden = false
        }
        stageNote.stringValue = DockSettings.isStageManagerOn
            ? "检测到已开启「台前调度」，程序坞预览暂停工作（窗口切换器不受影响）" : ""

        let key = HotkeyConfig.shared.binding(for: .windowSwitcher)
        switcherHint.stringValue = key.isNone
            ? "跨应用按窗口切换（未设置快捷键，可在「快捷键」页设置，或从菜单栏打开）"
            : "按住修饰键连按 \(key.displayString) 选择窗口，松开即切换；⇧ 反向 · 方向键移动 · W 关闭 · M 最小化 · Q 退出应用 · Esc 取消"
    }

    // MARK: 动作
    @objc private func togglePreview(_ s: NSButton) { DockSettings.previewEnabled = s.state == .on }
    @objc private func changeDelay(_ s: NSPopUpButton) { DockSettings.hoverDelay = Double(s.selectedTag()) / 1000 }
    @objc private func changeSize(_ s: NSPopUpButton) { DockSettings.thumbSize = s.selectedTag() }
    @objc private func toggleMinimized(_ s: NSButton) { DockSettings.showMinimized = s.state == .on }
    @objc private func toggleOtherSpaces(_ s: NSButton) { DockSettings.showOtherSpaces = s.state == .on }
    @objc private func toggleTitles(_ s: NSButton) { DockSettings.showTitles = s.state == .on }
    @objc private func toggleSwitcher(_ s: NSButton) { DockSettings.switcherEnabled = s.state == .on }

    @objc private func requestAX() { ClipboardController.requestAccessibility() }

    @objc private func requestSR() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let self = self else { return }
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier, !self.ignored.contains(bid) {
                    self.ignored.append(bid)
                }
            }
            DockSettings.ignoredApps = self.ignored
            self.ignoreTable.reloadData()
        }
    }

    @objc private func removeIgnoredApp() {
        let rows = ignoreTable.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        ignored = ignored.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        DockSettings.ignoredApps = ignored
        ignoreTable.reloadData()
    }

    // MARK: 列表
    func numberOfRows(in tableView: NSTableView) -> Int { ignored.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bid = ignored[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 22))
        let iv = NSImageView(frame: NSRect(x: 4, y: 3, width: 16, height: 16))
        let tf = NSTextField(labelWithString: "")
        tf.frame = NSRect(x: 26, y: 3, width: tableView.bounds.width - 30, height: 16)
        tf.lineBreakMode = .byTruncatingTail
        tf.autoresizingMask = [.width]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            iv.image = NSWorkspace.shared.icon(forFile: url.path)
            tf.stringValue = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            tf.toolTip = bid
        } else {
            iv.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            tf.stringValue = "\(bid)（未安装）"
            tf.textColor = .secondaryLabelColor
        }
        cell.addSubview(iv)
        cell.addSubview(tf)
        return cell
    }
}
