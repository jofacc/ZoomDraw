import AppKit

/// 偏好设置 →「快捷搜索」标签页：管理 ⌘1–⌘9 对应的模板（网页 / AI 搜索 / AI 指令）
final class WebSearchPrefsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var engines: [WebSearchEngine] = WebSearch.engines
    private let table = NSTableView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let testField = NSTextField(string: "天气")
    private let browserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeButton = NSButton(title: "删除", target: nil, action: nil)
    private let upButton = NSButton(title: "上移", target: nil, action: nil)
    private let downButton = NSButton(title: "下移", target: nil, action: nil)
    private let promptButton = NSButton(title: "编辑提示词…", target: nil, action: nil)

    private static let dragType = NSPasteboard.PasteboardType("com.zoomdraw.websearch.row")
    private enum Col: String { case enabled, key, kind, name, url }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(hotkeysChanged),
                                               name: .hotkeysChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 构建
    private func build() {
        let W = bounds.width, H = bounds.height
        let pad: CGFloat = 16

        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: pad, y: H - 52, width: W - pad * 2, height: 40)
        hint.autoresizingMask = [.width, .minYMargin]
        addSubview(hint)
        updateHint()

        // 列表
        let listTop = H - 60, listH: CGFloat = 268
        let scroll = NSScrollView(frame: NSRect(x: pad, y: listTop - listH, width: W - pad * 2, height: listH))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .minYMargin]

        let cols: [(Col, String, CGFloat)] = [(.enabled, "", 24), (.key, "快捷键", 44), (.kind, "类型", 82), (.name, "名称", 84),
                                              (.url, "网址模板 / 提示词（{query} 为输入内容）",
                                               scroll.contentSize.width - 24 - 44 - 82 - 84 - 14)]
        for (c, title, w) in cols {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = title
            col.width = w
            col.minWidth = c == .url ? 120 : w
            col.resizingMask = c == .url ? .autoresizingMask : []
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        addSubview(scroll)

        // 按钮行
        var y = scroll.frame.minY - 30
        var x = pad
        func button(_ b: NSButton, _ action: Selector, width: CGFloat? = nil) {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            b.target = self
            b.action = action
            b.sizeToFit()
            b.frame = NSRect(x: x, y: y, width: max(width ?? 0, b.frame.width + 8), height: 24)
            b.autoresizingMask = [.minYMargin]
            addSubview(b)
            x = b.frame.maxX + 4
        }
        button(NSButton(title: "添加 ▾", target: nil, action: nil), #selector(addEngine(_:)))
        button(removeButton, #selector(removeEngine))
        button(upButton, #selector(moveRowUp))
        button(downButton, #selector(moveRowDown))
        button(promptButton, #selector(editPrompt))
        let reset = NSButton(title: "恢复预置模板", target: nil, action: nil)
        button(reset, #selector(resetPresets))
        reset.frame.origin.x = W - pad - reset.frame.width
        reset.autoresizingMask = [.minYMargin, .minXMargin]

        y -= 22
        status.font = NSFont.systemFont(ofSize: 11)
        status.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        status.lineBreakMode = .byTruncatingTail
        status.autoresizingMask = [.width, .minYMargin]
        addSubview(status)

        // 测试
        y -= 36
        let testLabel = NSTextField(labelWithString: "测试关键字")
        testLabel.frame = NSRect(x: pad, y: y + 3, width: 70, height: 17)
        testLabel.autoresizingMask = [.minYMargin]
        addSubview(testLabel)
        testField.frame = NSRect(x: pad + 74, y: y, width: 160, height: 22)
        testField.autoresizingMask = [.minYMargin]
        addSubview(testField)
        x = testField.frame.maxX + 8
        button(NSButton(title: "用选中的模板打开", target: nil, action: nil), #selector(testSelected))

        // 浏览器
        y -= 36
        let bl = NSTextField(labelWithString: "打开网页使用")
        bl.frame = NSRect(x: pad, y: y + 3, width: 84, height: 17)
        bl.autoresizingMask = [.minYMargin]
        addSubview(bl)
        browserPopup.frame = NSRect(x: pad + 86, y: y - 2, width: 220, height: 26)
        browserPopup.target = self
        browserPopup.action = #selector(browserChanged)
        browserPopup.autoresizingMask = [.minYMargin]
        addSubview(browserPopup)
        fillBrowsers()

        let note = NSTextField(labelWithString: "只对 http / https 网址生效；dict://、shortcuts:// 等由对应应用打开")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: pad, y: y - 24, width: W - pad * 2, height: 15)
        note.autoresizingMask = [.minYMargin, .width]
        addSubview(note)

        table.reloadData()
        if !engines.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateState()
    }

    private func updateHint() {
        let clip = HotkeyConfig.shared.binding(for: .clipboard)
        let open = clip.isNone ? "剪贴板历史" : "剪贴板历史（\(clip.displayString)）"
        hint.stringValue = "在\(open)的输入框中输入内容，按 ⌘1–⌘9 用对应模板处理（AI 搜索 / AI 指令 / 打开网页）；"
            + "输入框为空时处理当前选中的条目。已勾选的前 \(WebSearch.maxShortcuts) 个按顺序对应 ⌘1–⌘9，可拖动排序。"
    }

    @objc private func hotkeysChanged() { updateHint() }

    private func fillBrowsers() {
        browserPopup.removeAllItems()
        browserPopup.addItem(withTitle: "系统默认浏览器")
        browserPopup.lastItem?.representedObject = nil
        browserPopup.menu?.addItem(.separator())
        let current = WebSearch.browserBundleID
        var selected = false
        for url in WebSearch.installedBrowsers() {
            guard let bid = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = bid
            browserPopup.menu?.addItem(item)
            if bid == current { browserPopup.select(item); selected = true }
        }
        if !selected { browserPopup.selectItem(at: 0) }
    }

    // MARK: 状态
    /// 每个已启用模板对应的快捷键序号（从 0 开始）；超过 9 个或无效的为 nil
    private func shortcutIndex(of row: Int) -> Int? {
        var n = 0
        for (i, e) in engines.enumerated() where e.enabled && e.isValid {
            if i == row { return n < WebSearch.maxShortcuts ? n : nil }
            n += 1
        }
        return nil
    }

    private func updateState() {
        let row = table.selectedRow
        let has = row >= 0 && row < engines.count
        removeButton.isEnabled = has
        upButton.isEnabled = has && row > 0
        downButton.isEnabled = has && row < engines.count - 1
        promptButton.isEnabled = has && engines[row].isAI

        let enabledCount = engines.filter { $0.enabled && $0.isValid }.count
        if has, let err = engines[row].validationError {
            status.stringValue = "⚠️ 「\(engines[row].name)」：\(err)"
            status.textColor = .systemOrange
        } else if enabledCount > WebSearch.maxShortcuts {
            status.stringValue = "已勾选 \(enabledCount) 个，只有前 \(WebSearch.maxShortcuts) 个有快捷键"
            status.textColor = .systemOrange
        } else {
            status.stringValue = "已勾选 \(enabledCount) 个模板 · 共 \(engines.count) 个"
            status.textColor = .secondaryLabelColor
        }
    }

    private func save(reload: Bool = true) {
        WebSearch.engines = engines
        if reload {
            let sel = table.selectedRow
            table.reloadData()
            if sel >= 0 && sel < engines.count { table.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false) }
        }
        updateState()
    }

    // MARK: 动作
    @objc private func addEngine(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, tag) in [("网页模板", 0), ("AI 指令", 1), ("AI 搜索", 2)] {
            let item = NSMenuItem(title: title, action: #selector(addEngineOfKind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func addEngineOfKind(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1:
            engines.append(WebSearchEngine(name: "新指令", kind: .aiPrompt, prompt: Self.defaultPrompt, enabled: true))
        case 2:
            engines.append(WebSearchEngine(name: "AI 搜索", kind: .aiSearch, prompt: "", enabled: true))
        default:
            engines.append(WebSearchEngine(name: "新模板", url: "https://example.com/search?q={query}", enabled: true))
        }
        save()
        let row = engines.count - 1
        if sender.tag == 1 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            editPrompt()
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == Col.name.rawValue }),
           let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
           let tf = cell.textField {
            window?.makeFirstResponder(tf)
        }
    }

    @objc private func removeEngine() {
        let row = table.selectedRow
        guard row >= 0 && row < engines.count else { return }
        engines.remove(at: row)
        save()
        if !engines.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(row, engines.count - 1)), byExtendingSelection: false)
        }
        updateState()
    }

    @objc private func moveRowUp() { move(by: -1) }
    @objc private func moveRowDown() { move(by: 1) }

    private func move(by d: Int) {
        let row = table.selectedRow, to = row + d
        guard row >= 0, to >= 0, to < engines.count else { return }
        engines.swapAt(row, to)
        save()
        table.selectRowIndexes(IndexSet(integer: to), byExtendingSelection: false)
        table.scrollRowToVisible(to)
        updateState()
    }

    @objc private func resetPresets() {
        let alert = NSAlert()
        alert.messageText = "恢复预置模板？"
        alert.informativeText = "当前的模板列表会被替换为预置的 \(WebSearch.presets.count) 个模板，自定义的模板将被删除。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            self.engines = WebSearch.presets
            self.save()
            self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func testSelected() {
        window?.makeFirstResponder(nil)   // 先提交正在编辑的单元格
        let row = table.selectedRow
        guard row >= 0 && row < engines.count else { NSSound.beep(); return }
        let q = testField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { NSSound.beep(); return }
        if engines[row].isAI {
            status.stringValue = "AI 模板请在剪贴板面板中按对应的 ⌘ 数字键使用"
            status.textColor = .secondaryLabelColor
            return
        }
        if !WebSearch.open(engines[row], query: q) {
            status.stringValue = "⚠️ 无法打开：\(engines[row].validationError ?? "网址格式不正确")"
            status.textColor = .systemOrange
        }
    }

    @objc private func browserChanged() {
        WebSearch.browserBundleID = browserPopup.selectedItem?.representedObject as? String
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 && row < engines.count else { return }
        engines[row].enabled = sender.state == .on
        save()
    }

    private static let defaultPrompt = "请处理下面的内容：\n\n{query}"

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard row >= 0 && row < engines.count,
              let kind = WebSearchEngine.Kind.allCases.first(where: { $0.rawValue == sender.selectedItem?.representedObject as? String }),
              kind != engines[row].kind else { return }
        engines[row].kind = kind
        if kind == .aiPrompt && engines[row].prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            engines[row].prompt = Self.defaultPrompt
        }
        if kind == .web && engines[row].url.isEmpty { engines[row].url = "https://example.com/search?q={query}" }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        save()
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0 && row < engines.count, engines[row].isAI else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        editPrompt()
    }

    /// 编辑 AI 指令的提示词 / AI 搜索的额外要求
    @objc private func editPrompt() {
        window?.makeFirstResponder(nil)
        let row = table.selectedRow
        guard row >= 0 && row < engines.count, engines[row].isAI, let w = window else { return }
        let e = engines[row]
        let alert = NSAlert()
        alert.messageText = e.kind == .aiPrompt ? "编辑「\(e.name)」的提示词" : "「\(e.name)」的额外要求（可选）"
        alert.informativeText = e.kind == .aiPrompt
            ? "{query} 会被替换为输入框里的内容或选中的条目；不写 {query} 时，内容会附在提示词后面。选中图片时会把图片一起发给 AI。"
            : "AI 搜索会先联网搜索，再依据搜索结果回答并标注来源。这里可以补充要求，例如“回答尽量简短”“优先参考官方网站”。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.autoresizingMask = [.width]
        tv.string = e.prompt
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = tv
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self, row < self.engines.count,
                  self.engines[row].id == e.id else { return }
            self.engines[row].prompt = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            self.save()
        }
    }

    // MARK: 编辑
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf !== testField else { return }
        let row = table.row(for: tf)
        guard row >= 0 && row < engines.count else { return }
        let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
        switch tf.identifier?.rawValue {
        case Col.name.rawValue:
            guard v != engines[row].name else { return }
            engines[row].name = v
        case Col.url.rawValue:
            guard engines[row].kind == .web, v != engines[row].url else { return }
            engines[row].url = v
        default: return
        }
        // 结束编辑的通知里直接刷新表格会打断下一个单元格的编辑，放到下一轮
        DispatchQueue.main.async { [weak self] in self?.save() }
    }

    // MARK: 表格
    func numberOfRows(in tableView: NSTableView) -> Int { engines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let col = Col(rawValue: id) else { return nil }
        let e = engines[row]
        let w = tableColumn?.width ?? 100
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: w, height: 24))
        switch col {
        case .enabled:
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            b.state = e.enabled ? .on : .off
            b.frame = NSRect(x: 4, y: 3, width: 18, height: 18)
            cell.addSubview(b)
        case .key:
            let tf = NSTextField(labelWithString: shortcutIndex(of: row).map { "⌘\($0 + 1)" } ?? "—")
            tf.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            tf.textColor = shortcutIndex(of: row) == nil ? .tertiaryLabelColor : .labelColor
            tf.alignment = .center
            tf.frame = NSRect(x: 0, y: 4, width: w, height: 16)
            tf.autoresizingMask = [.width]
            cell.addSubview(tf)
        case .kind:
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: w, height: 24), pullsDown: false)
            p.controlSize = .small
            p.font = NSFont.systemFont(ofSize: 11)
            p.isBordered = false
            for k in WebSearchEngine.Kind.allCases {
                p.addItem(withTitle: k.title)
                p.lastItem?.representedObject = k.rawValue
                if k == e.kind { p.select(p.lastItem) }
            }
            p.target = self
            p.action = #selector(kindChanged(_:))
            p.autoresizingMask = [.width]
            cell.addSubview(p)
        case .url where e.isAI:
            let tf = NSTextField(labelWithString: e.detail)
            tf.font = NSFont.systemFont(ofSize: 11.5)
            tf.textColor = e.validationError != nil ? .systemOrange : .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingTail
            tf.frame = NSRect(x: 2, y: 4, width: w - 4, height: 16)
            tf.autoresizingMask = [.width]
            tf.toolTip = (e.prompt.isEmpty ? e.detail : e.prompt) + "\n\n双击编辑"
            cell.addSubview(tf)
        case .name, .url:
            let tf = NSTextField(string: col == .name ? e.name : e.url)
            tf.identifier = .init(col.rawValue)
            tf.isBordered = false
            tf.drawsBackground = false
            tf.focusRingType = .none
            tf.font = col == .url ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.usesSingleLineMode = true
            tf.delegate = self
            tf.frame = NSRect(x: 2, y: 3, width: w - 4, height: 18)
            tf.autoresizingMask = [.width]
            if !e.enabled { tf.textColor = .secondaryLabelColor }
            if col == .url, e.validationError != nil { tf.textColor = .systemOrange }
            tf.toolTip = col == .url ? e.url : nil
            cell.addSubview(tf)
            cell.textField = tf
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateState() }

    // 拖动排序
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(s), from >= 0, from < engines.count else { return false }
        let e = engines.remove(at: from)
        let to = from < row ? row - 1 : row
        engines.insert(e, at: max(0, min(to, engines.count)))
        save()
        table.selectRowIndexes(IndexSet(integer: max(0, min(to, engines.count - 1))), byExtendingSelection: false)
        updateState()
        return true
    }
}
