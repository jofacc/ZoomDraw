import AppKit
import UniformTypeIdentifiers

/// 偏好设置 →「剪贴板」标签页
final class ClipboardPrefsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "去授权…", target: nil, action: nil)
    private let accessWarning = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "打开隐私设置…", target: nil, action: nil)
    private let ignoreTable = NSTableView()
    private var ignored: [String] = ClipboardSettings.ignoredApps
    private var keyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// 切到本页 / 从系统设置回来时刷新权限状态
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
            l.autoresizingMask = [.minYMargin]
            addSubview(l)
            return l
        }
        func checkbox(_ s: String, on: Bool, x: CGFloat, y: CGFloat, w: CGFloat, action: Selector) -> NSButton {
            let b = NSButton(checkboxWithTitle: s, target: self, action: action)
            b.state = on ? .on : .off
            b.frame = NSRect(x: x, y: y, width: w, height: 20)
            b.autoresizingMask = [.minYMargin]
            addSubview(b)
            return b
        }
        func popup(x: CGFloat, y: CGFloat, w: CGFloat, items: [(String, Int)], selected: Int,
                   action: Selector) -> NSPopUpButton {
            let p = NSPopUpButton(frame: NSRect(x: x, y: y - 4, width: w, height: 26), pullsDown: false)
            for (t, tag) in items { p.addItem(withTitle: t); p.lastItem?.tag = tag }
            p.selectItem(withTag: selected)
            p.target = self
            p.action = action
            p.autoresizingMask = [.minYMargin]
            addSubview(p)
            return p
        }

        // 1. 总开关
        _ = checkbox("记录剪贴板历史", on: ClipboardSettings.enabled, x: pad, y: y, w: 300,
                     action: #selector(toggleEnabled(_:)))
        _ = label("关闭后不再记录新内容，已有记录保留", x: pad + 18, y: y - 18, w: W - pad * 2, size: 11, secondary: true)
        y -= 46

        // 2. 记录类型
        _ = label("记录内容", x: pad, y: y, w: 80)
        _ = checkbox("文本与链接", on: ClipboardSettings.recordText, x: pad + 90, y: y, w: 110,
                     action: #selector(toggleText(_:)))
        _ = checkbox("图片", on: ClipboardSettings.recordImages, x: pad + 205, y: y, w: 70,
                     action: #selector(toggleImages(_:)))
        _ = checkbox("文件", on: ClipboardSettings.recordFiles, x: pad + 280, y: y, w: 70,
                     action: #selector(toggleFiles(_:)))
        y -= 38

        // 3. 保留规则
        _ = label("最多保留", x: pad, y: y, w: 80)
        _ = popup(x: pad + 86, y: y, w: 110,
                  items: ClipboardSettings.maxItemsOptions.map { ("\($0) 条", $0) },
                  selected: ClipboardSettings.maxItems, action: #selector(changeMaxItems(_:)))
        _ = label("保留时长", x: pad + 220, y: y, w: 70)
        _ = popup(x: pad + 290, y: y, w: 110,
                  items: ClipboardSettings.maxDaysOptions.map { d in
                      let t: String
                      switch d {
                      case 0: t = "永久"
                      case 1: t = "1 天"
                      case 7: t = "7 天"
                      case 30: t = "1 个月"
                      case 90: t = "3 个月"
                      default: t = "\(d) 天"
                      }
                      return (t, d)
                  },
                  selected: ClipboardSettings.maxDays, action: #selector(changeMaxDays(_:)))
        y -= 22
        _ = label("固定（⌘P）的条目不占条数，也不会过期", x: pad, y: y, w: W - pad * 2, size: 11, secondary: true)
        y -= 34

        // 4. 自动粘贴 + 权限状态
        _ = checkbox("选中后自动粘贴到当前应用", on: ClipboardSettings.autoPaste, x: pad, y: y, w: 260,
                     action: #selector(toggleAutoPaste(_:)))
        axStatus.font = NSFont.systemFont(ofSize: 11)
        axStatus.frame = NSRect(x: pad + 18, y: y - 20, width: 240, height: 16)
        axStatus.autoresizingMask = [.minYMargin]
        addSubview(axStatus)
        axButton.bezelStyle = .rounded
        axButton.controlSize = .small
        axButton.target = self
        axButton.action = #selector(requestAX)
        axButton.frame = NSRect(x: pad + 262, y: y - 24, width: 90, height: 24)
        axButton.autoresizingMask = [.minYMargin]
        addSubview(axButton)
        y -= 46

        // 5. 纯文本
        _ = checkbox("默认以纯文本粘贴", on: ClipboardSettings.plainTextDefault, x: pad, y: y, w: 260,
                     action: #selector(togglePlain(_:)))
        _ = label("按 ⇧⏎ 可临时切换为另一种方式", x: pad + 18, y: y - 18, w: W - pad * 2, size: 11, secondary: true)
        y -= 46

        // 6. 忽略的应用
        _ = label("不记录以下应用中的复制（默认已包含常见密码管理器）", x: pad, y: y, w: W - pad * 2)
        let listH: CGFloat = 96
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
        y -= 40

        // 7. 清除
        let clear = NSButton(title: "清除全部历史…", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: pad - 6, y: y, width: 130, height: 28)
        clear.autoresizingMask = [.minYMargin]
        addSubview(clear)
        _ = label("固定的条目会保留", x: pad + 132, y: y + 6, w: 160, size: 11, secondary: true)

        // 8. 系统剪贴板访问权限（macOS 15.4+ 才有此机制）
        accessWarning.font = NSFont.systemFont(ofSize: 11)
        accessWarning.textColor = .systemOrange
        accessWarning.frame = NSRect(x: pad, y: 12, width: W - pad * 2 - 120, height: 30)
        accessWarning.maximumNumberOfLines = 2
        accessWarning.lineBreakMode = .byWordWrapping
        accessWarning.cell?.wraps = true
        accessWarning.autoresizingMask = [.maxYMargin, .width]
        addSubview(accessWarning)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        accessButton.target = self
        accessButton.action = #selector(openPasteboardPrivacy)
        accessButton.frame = NSRect(x: W - pad - 112, y: 16, width: 112, height: 24)
        accessButton.autoresizingMask = [.maxYMargin, .minXMargin]
        addSubview(accessButton)
    }

    private func refreshStatus() {
        if ClipboardController.isAccessibilityTrusted {
            axStatus.stringValue = "✓ 已获得辅助功能权限"
            axStatus.textColor = .systemGreen
            axButton.isHidden = true
        } else {
            axStatus.stringValue = "未授权辅助功能：只复制，需手动按 ⌘V"
            axStatus.textColor = .systemOrange
            axButton.isHidden = false
        }

        var warning: String?
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysDeny:
                warning = "系统已禁止本应用读取剪贴板，历史无法记录。请在「隐私与安全性 → 从其他 App 粘贴」中允许 ZoomDraw。"
            case .ask:
                warning = "系统会在每次读取剪贴板时询问。建议在「隐私与安全性 → 从其他 App 粘贴」中选择「允许」。"
            default:
                warning = nil
            }
        }
        accessWarning.stringValue = warning ?? ""
        accessWarning.isHidden = warning == nil
        accessButton.isHidden = warning == nil
    }

    // MARK: 动作
    @objc private func toggleEnabled(_ s: NSButton) { ClipboardSettings.enabled = s.state == .on }
    @objc private func toggleText(_ s: NSButton) { ClipboardSettings.recordText = s.state == .on }
    @objc private func toggleImages(_ s: NSButton) { ClipboardSettings.recordImages = s.state == .on }
    @objc private func toggleFiles(_ s: NSButton) { ClipboardSettings.recordFiles = s.state == .on }
    @objc private func changeMaxItems(_ s: NSPopUpButton) { ClipboardSettings.maxItems = s.selectedTag() }
    @objc private func changeMaxDays(_ s: NSPopUpButton) { ClipboardSettings.maxDays = s.selectedTag() }
    @objc private func toggleAutoPaste(_ s: NSButton) { ClipboardSettings.autoPaste = s.state == .on }
    @objc private func togglePlain(_ s: NSButton) { ClipboardSettings.plainTextDefault = s.state == .on }

    @objc private func requestAX() {
        ClipboardController.requestAccessibility()
    }

    @objc private func openPasteboardPrivacy() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清除全部剪贴板历史？"
        alert.informativeText = "固定的条目会保留。此操作无法撤销。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { resp in
            if resp == .alertFirstButtonReturn {
                ClipboardStore.shared.clear(lastMinutes: nil)
            }
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
            ClipboardSettings.ignoredApps = self.ignored
            self.ignoreTable.reloadData()
        }
    }

    @objc private func removeIgnoredApp() {
        let rows = ignoreTable.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        ignored = ignored.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        ClipboardSettings.ignoredApps = ignored
        ignoreTable.reloadData()
    }

    // MARK: 忽略列表
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
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            tf.stringValue = name
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
