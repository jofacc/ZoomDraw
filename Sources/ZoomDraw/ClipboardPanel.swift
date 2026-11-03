import AppKit
import QuickLookThumbnailing

/// 剪贴板历史浮窗：不激活本应用，键盘输入直接进入面板，前台应用保持不变（粘贴才能回到原输入位置）
final class ClipboardPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let h = keyHandler, h(event) { return }
        super.sendEvent(event)
    }
}

enum ClipFilter: Int, CaseIterable {
    case all, text, image, file, link, pinned

    var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        case .link: return "链接"
        case .pinned: return "★ 固定"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text || item.kind == .color
        case .image: return item.kind == .image
        case .file: return item.kind == .file
        case .link: return item.kind == .link
        case .pinned: return item.pinned
        }
    }
}

/// 面板内容：搜索框 + 分类 + 列表 + 预览 + 底部提示
final class ClipboardHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onActivate: ((ClipItem, _ plain: Bool) -> Void)?
    var onCopyOnly: ((ClipItem) -> Void)?
    var onSaveToShelf: ((ClipItem) -> Void)?
    var onOpen: ((ClipItem) -> Void)?
    var onClose: (() -> Void)?

    let searchField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let filterControl: NSSegmentedControl
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let preview = ClipPreviewView()
    private let footer = NSTextField(labelWithString: "")

    private var filter: ClipFilter = .all
    private var visible: [ClipItem] = []

    private let thumbCache = NSCache<NSString, NSImage>()

    static let size = NSSize(width: 780, height: 470)
    private static let headerH: CGFloat = 54
    private static let filterH: CGFloat = 36
    private static let footerH: CGFloat = 30
    private static let listW: CGFloat = 380

    override init(frame: NSRect) {
        filterControl = NSSegmentedControl(labels: ClipFilter.allCases.map(\.title),
                                           trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .clipboardHistoryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .clipboardStateChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 构建
    private func build() {
        let W = bounds.width, H = bounds.height

        let bg = NSVisualEffectView(frame: bounds)
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)

        // 头部：搜索
        let headerY = H - Self.headerH
        let icon = NSImageView(frame: NSRect(x: 18, y: headerY + 16, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        bg.addSubview(icon)

        searchField.frame = NSRect(x: 48, y: headerY + 13, width: W - 48 - 170, height: 28)
        searchField.font = NSFont.systemFont(ofSize: 19, weight: .regular)
        searchField.placeholderString = "搜索剪贴板历史"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        bg.addSubview(searchField)

        statusLabel.frame = NSRect(x: W - 160, y: headerY + 19, width: 142, height: 16)
        statusLabel.alignment = .right
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        bg.addSubview(statusLabel)

        bg.addSubview(separator(NSRect(x: 0, y: headerY, width: W, height: 1)))

        // 分类
        let filterY = headerY - Self.filterH
        filterControl.segmentStyle = .rounded
        filterControl.controlSize = .regular
        filterControl.font = NSFont.systemFont(ofSize: 12.5)
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterClicked)
        filterControl.sizeToFit()
        filterControl.frame.origin = NSPoint(x: 14, y: filterY + (Self.filterH - filterControl.frame.height) / 2)
        bg.addSubview(filterControl)

        // 列表
        let mainY = Self.footerH + 1
        let mainH = filterY - mainY
        scrollView.frame = NSRect(x: 0, y: mainY, width: Self.listW, height: mainH)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let col = NSTableColumn(identifier: .init("clip"))
        col.width = Self.listW - 4
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        scrollView.documentView = tableView
        bg.addSubview(scrollView)

        emptyLabel.frame = NSRect(x: 20, y: mainY + mainH / 2 - 20, width: Self.listW - 40, height: 40)
        emptyLabel.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 2
        bg.addSubview(emptyLabel)

        bg.addSubview(separator(NSRect(x: Self.listW, y: mainY, width: 1, height: mainH)))

        // 预览
        preview.frame = NSRect(x: Self.listW + 1, y: mainY, width: W - Self.listW - 1, height: mainH)
        bg.addSubview(preview)

        // 底部提示
        bg.addSubview(separator(NSRect(x: 0, y: Self.footerH, width: W, height: 1)))
        footer.frame = NSRect(x: 14, y: 8, width: W - 28, height: 15)
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        bg.addSubview(footer)
    }

    private func separator(_ frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    // MARK: 数据
    /// 每次打开面板时调用：清空搜索、回到「全部」、选中第一条
    func prepareForShow() {
        searchField.stringValue = ""
        filter = .all
        filterControl.selectedSegment = 0
        reload(keepSelection: false)
        updateFooter()
        updateStatus()
        window?.makeFirstResponder(searchField)
    }

    private func reload(keepSelection: Bool) {
        let selectedID = keepSelection ? selectedItem?.id : nil
        let tokens = searchField.stringValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        visible = ClipboardStore.shared.items.filter { item in
            guard filter.matches(item) else { return false }
            guard !tokens.isEmpty else { return true }
            let hay = item.text + "\n" + item.title + "\n" + (item.sourceName ?? "")
            return tokens.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        tableView.reloadData()

        var row = 0
        if let id = selectedID, let idx = visible.firstIndex(where: { $0.id == id }) { row = idx }
        if visible.isEmpty {
            tableView.deselectAll(nil)
            preview.show(nil)
        } else {
            select(row: row)
        }
        updateEmptyState()
        updateStatus()
    }

    private func updateEmptyState() {
        guard visible.isEmpty else { emptyLabel.isHidden = true; return }
        emptyLabel.isHidden = false
        if !ClipboardSettings.enabled {
            emptyLabel.stringValue = "剪贴板历史已关闭\n可在「偏好设置 → 剪贴板」中开启"
        } else if ClipboardStore.shared.items.isEmpty {
            emptyLabel.stringValue = "还没有剪贴板记录\n复制任何内容后会出现在这里"
        } else {
            emptyLabel.stringValue = "没有匹配的结果"
        }
    }

    private func updateStatus() {
        if !ClipboardSettings.enabled {
            statusLabel.stringValue = "记录已关闭"
        } else if ClipboardStore.shared.isPaused {
            statusLabel.stringValue = "⏸ 已暂停记录"
        } else {
            statusLabel.stringValue = "\(ClipboardStore.shared.items.count) 条记录"
        }
    }

    private func updateFooter() {
        let verb = ClipboardSettings.autoPaste ? "粘贴" : "复制"
        let alt = ClipboardSettings.plainTextDefault ? "保留格式" : "纯文本"
        footer.stringValue = "⏎ \(verb)    ⇧⏎ \(alt)    ⌘1–9 快速\(verb)    ⌘C 仅复制    ⌘P 固定    ⌘⌫ 删除    ⌘S 存入暂存板    ⌘O 打开    Esc 关闭"
    }

    @objc private func historyChanged() {
        guard window?.isVisible == true else { return }
        reload(keepSelection: true)
    }

    @objc private func stateChanged() {
        updateStatus()
        updateEmptyState()
    }

    var selectedItem: ClipItem? {
        let r = tableView.selectedRow
        return r >= 0 && r < visible.count ? visible[r] : nil
    }

    private func select(row: Int) {
        guard !visible.isEmpty else { return }
        let r = max(0, min(visible.count - 1, row))
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    // MARK: 键盘
    func handleKey(_ e: NSEvent) -> Bool {
        let editor = searchField.currentEditor() as? NSTextView
        // 输入法正在组字时，方向键 / 回车 / Esc 交给输入法
        if editor?.hasMarkedText() == true { return false }

        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 53: onClose?(); return true
        case 126:
            select(row: mods.contains(.command) ? 0 : tableView.selectedRow - 1); return true
        case 125:
            select(row: mods.contains(.command) ? visible.count - 1 : tableView.selectedRow + 1); return true
        case 116: select(row: tableView.selectedRow - 8); return true
        case 121: select(row: tableView.selectedRow + 8); return true
        case 36, 76:
            if let item = selectedItem {
                onActivate?(item, mods.contains(.shift) != ClipboardSettings.plainTextDefault)
            }
            return true
        case 48:
            let n = ClipFilter.allCases.count
            let next = (filter.rawValue + (mods.contains(.shift) ? n - 1 : 1)) % n
            setFilter(ClipFilter(rawValue: next) ?? .all)
            return true
        default: break
        }

        guard mods == [.command] else { return false }
        let numberKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        if let idx = numberKeys[e.keyCode] {
            if idx < visible.count { onActivate?(visible[idx], ClipboardSettings.plainTextDefault) }
            return true
        }
        switch e.keyCode {
        case 8: // ⌘C：搜索框有选中文字时复制文字，否则复制条目
            if let ed = editor, ed.selectedRange().length > 0 { ed.copy(nil) }
            else if let item = selectedItem { onCopyOnly?(item) }
            return true
        case 35: // ⌘P
            if let item = selectedItem { ClipboardStore.shared.togglePin(item.id) }
            return true
        case 51: // ⌘⌫
            if let item = selectedItem {
                let row = tableView.selectedRow
                ClipboardStore.shared.remove(item.id)
                select(row: row)
            }
            return true
        case 1: // ⌘S
            if let item = selectedItem { onSaveToShelf?(item) }
            return true
        case 31: // ⌘O
            if let item = selectedItem { onOpen?(item) }
            return true
        case 13: onClose?(); return true            // ⌘W
        case 0: editor?.selectAll(nil); return true // ⌘A
        case 9: editor?.paste(nil); return true     // ⌘V
        case 7: editor?.cut(nil); return true       // ⌘X
        case 6: editor?.undoManager?.undo(); return true // ⌘Z
        default: return false
        }
    }

    private func setFilter(_ f: ClipFilter) {
        filter = f
        filterControl.selectedSegment = f.rawValue
        reload(keepSelection: true)
    }

    @objc private func filterClicked() {
        setFilter(ClipFilter(rawValue: filterControl.selectedSegment) ?? .all)
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        reload(keepSelection: false)
    }

    @objc private func rowClicked() {
        window?.makeFirstResponder(searchField)
        if let ed = searchField.currentEditor() {
            ed.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    @objc private func rowDoubleClicked() {
        let r = tableView.clickedRow
        guard r >= 0, r < visible.count else { return }
        onActivate?(visible[r], ClipboardSettings.plainTextDefault)
    }

    // MARK: 表格
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ClipCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipCellView) ?? {
            let c = ClipCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
            c.identifier = id
            return c
        }()
        let item = visible[row]
        cell.configure(item: item, index: row, icon: icon(for: item))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        preview.show(selectedItem)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < visible.count else { return nil }
        let item = visible[row]
        let store = ClipboardStore.shared
        switch item.kind {
        case .text, .color:
            return store.fullText(of: item) as NSString
        case .link:
            let pi = NSPasteboardItem()
            pi.setString(item.text, forType: .URL)
            pi.setString(item.text, forType: .string)
            return pi
        case .file:
            return item.existingFileURLs.first as NSURL?
        case .image:
            guard let url = ClipboardController.exportImage(item) else { return nil }
            return url as NSURL
        }
    }

    // MARK: 图标
    private func icon(for item: ClipItem) -> NSImage? {
        switch item.kind {
        case .image:
            let key = item.id.uuidString as NSString
            if let img = thumbCache.object(forKey: key) { return img }
            if let img = NSImage(contentsOf: ClipboardStore.shared.thumbURL(item.id)) {
                thumbCache.setObject(img, forKey: key)
                return img
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .file:
            guard let first = item.fileURLs.first else { return nil }
            let key = ("f:" + first.path) as NSString
            if let img = thumbCache.object(forKey: key) { return img }
            let img = NSWorkspace.shared.icon(forFile: first.path)
            thumbCache.setObject(img, forKey: key)
            return img
        case .color:
            return ClipCellView.swatch(item.color ?? .clear, size: 28)
        case .link:
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }
    }

    // MARK: 时间
    static func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if Calendar.current.isDateInToday(date) {
            return "今天 " + timeFormatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f
    }()
}

// MARK: - 行视图

/// 自绘选中背景：面板不激活应用时系统会把选中色画成灰色，这里固定用强调色
final class ClipRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 8, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
    }
}

final class ClipCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sourceIcon = NSImageView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let pinView = NSImageView()

    private static var appIconCache: [String: NSImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        let W = frame.width

        iconView.frame = NSRect(x: 18, y: 8, width: 28, height: 28)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        titleLabel.frame = NSRect(x: 56, y: 22, width: W - 56 - 52, height: 17)
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)

        sourceIcon.frame = NSRect(x: 56, y: 6, width: 13, height: 13)
        addSubview(sourceIcon)

        subtitleLabel.frame = NSRect(x: 73, y: 5, width: W - 73 - 52, height: 14)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.autoresizingMask = [.width]
        addSubview(subtitleLabel)

        pinView.frame = NSRect(x: W - 50, y: 15, width: 14, height: 14)
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已固定")
        pinView.contentTintColor = .systemOrange
        pinView.autoresizingMask = [.minXMargin]
        addSubview(pinView)

        indexLabel.frame = NSRect(x: W - 36, y: 14, width: 26, height: 15)
        indexLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .right
        indexLabel.autoresizingMask = [.minXMargin]
        addSubview(indexLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: ClipItem, index: Int, icon: NSImage?) {
        iconView.image = icon
        titleLabel.stringValue = item.title.replacingOccurrences(of: "\t", with: " ")

        var parts: [String] = []
        if let name = item.sourceName { parts.append(name) }
        parts.append(ClipboardHistoryView.relativeTime(item.lastUsedAt))
        if item.kind == .file, item.existingFileURLs.isEmpty { parts.append("文件已不存在") }
        subtitleLabel.stringValue = parts.joined(separator: " · ")

        sourceIcon.image = Self.appIcon(item.sourceBundleID)
        let hasIcon = sourceIcon.image != nil
        sourceIcon.isHidden = !hasIcon
        var f = subtitleLabel.frame
        f.origin.x = hasIcon ? 73 : 56
        f.size.width = bounds.width - f.origin.x - 52
        subtitleLabel.frame = f

        pinView.isHidden = !item.pinned
        indexLabel.stringValue = index < 9 ? "⌘\(index + 1)" : ""
    }

    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bid = bundleID else { return nil }
        if let img = appIconCache[bid] { return img }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache[bid] = img
        return img
    }

    static func swatch(_ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            color.setFill(); p.fill()
            NSColor.separatorColor.setStroke(); p.lineWidth = 1; p.stroke()
            return true
        }
    }
}

// MARK: - 预览

final class ClipPreviewView: NSView {
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let swatchView = NSView()
    private let infoLabel = NSTextField(labelWithString: "")
    private var currentID: UUID?

    private static let infoH: CGFloat = 46

    override init(frame: NSRect) {
        super.init(frame: frame)

        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        addSubview(textScroll)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)

        swatchView.wantsLayer = true
        swatchView.layer?.cornerRadius = 12
        swatchView.layer?.borderWidth = 1
        swatchView.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(swatchView)

        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.maximumNumberOfLines = 2
        infoLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(infoLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        infoLabel.frame = NSRect(x: 14, y: 8, width: bounds.width - 28, height: Self.infoH - 14)
    }

    func show(_ item: ClipItem?) {
        currentID = item?.id
        textScroll.isHidden = true
        imageView.isHidden = true
        swatchView.isHidden = true
        imageView.image = nil
        needsLayout = true
        layoutSubtreeIfNeeded()

        guard let item = item else { infoLabel.stringValue = ""; return }
        let content = NSRect(x: 0, y: Self.infoH, width: bounds.width, height: bounds.height - Self.infoH)
        let store = ClipboardStore.shared

        var info: [String] = []
        if let s = item.sourceName { info.append("来源：\(s)") }
        info.append("复制于 " + ClipboardHistoryView.relativeTime(item.lastUsedAt))
        if item.copyCount > 1 { info.append("共复制 \(item.copyCount) 次") }

        switch item.kind {
        case .text, .link:
            let full = store.fullText(of: item)
            let shown = full.count > 200_000 ? String(full.prefix(200_000)) + "\n…" : full
            showText(shown, in: content, mono: false)
            info.append("\(full.count) 字")
        case .color:
            swatchView.isHidden = false
            let side = min(content.width - 60, content.height - 90, 160)
            swatchView.frame = NSRect(x: content.midX - side / 2, y: content.midY - side / 2 + 20,
                                      width: side, height: side)
            swatchView.layer?.backgroundColor = (item.color ?? .clear).cgColor
            textScroll.isHidden = false
            textScroll.frame = NSRect(x: 0, y: swatchView.frame.minY - 50, width: content.width, height: 40)
            textView.alignment = .center
            textView.string = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            textView.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        case .image:
            imageView.isHidden = false
            imageView.frame = content.insetBy(dx: 14, dy: 10)
            imageView.image = NSImage(contentsOf: store.imageURL(item.id))
            if let w = item.imageWidth, let h = item.imageHeight { info.append("\(w) × \(h)") }
            info.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
        case .file:
            let urls = item.fileURLs
            imageView.isHidden = false
            let iconH = min(content.height * 0.55, 180)
            imageView.frame = NSRect(x: 14, y: content.maxY - iconH - 10, width: content.width - 28, height: iconH)
            if let first = urls.first {
                imageView.image = NSWorkspace.shared.icon(forFile: first.path)
                loadThumbnail(for: first, id: item.id, size: NSSize(width: iconH, height: iconH))
            }
            let list = urls.map { url -> String in
                FileManager.default.fileExists(atPath: url.path) ? url.path : url.path + "（已不存在）"
            }.joined(separator: "\n")
            showText(list, in: NSRect(x: 0, y: content.minY, width: content.width,
                                      height: content.height - iconH - 14), mono: false)
            info.append("\(urls.count) 个文件")
        }
        infoLabel.stringValue = info.joined(separator: " · ")
    }

    private func showText(_ s: String, in rect: NSRect, mono: Bool) {
        textScroll.isHidden = false
        textScroll.frame = rect
        textView.alignment = .natural
        textView.font = mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                             : NSFont.systemFont(ofSize: 13)
        textView.string = s
        textView.frame = NSRect(origin: .zero, size: NSSize(width: rect.width, height: rect.height))
        textView.scrollToBeginningOfDocument(nil)
    }

    private func loadThumbnail(for url: URL, id: UUID, size: NSSize) {
        let scale = window?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep = rep else { return }
            DispatchQueue.main.async {
                guard let self = self, self.currentID == id else { return }
                self.imageView.image = rep.nsImage
            }
        }
    }
}
