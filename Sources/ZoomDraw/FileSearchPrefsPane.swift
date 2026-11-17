import AppKit

/// 偏好设置 →「文件搜索」标签页
final class FileSearchPrefsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let scopeTable = NSTableView()
    private var scopes: [String] = FileSearchSettings.scopes
    private let excludeField = NSTextField(string: "")
    private let extField = NSTextField(string: "")
    private var pageUpField: HotkeyRecorderField?
    private var pageDownField: HotkeyRecorderField?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func join(_ a: [String]) -> String { a.joined(separator: ", ") }
    private static func split(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: 构建
    private func build() {
        let W = bounds.width
        let pad: CGFloat = 20
        var y = bounds.height - 30

        func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 13,
                   secondary: Bool = false) {
            let l = NSTextField(labelWithString: s)
            l.font = NSFont.systemFont(ofSize: size)
            if secondary { l.textColor = .secondaryLabelColor }
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: x, y: y, width: w, height: size + 5)
            l.autoresizingMask = [.minYMargin]
            addSubview(l)
        }
        func checkbox(_ s: String, on: Bool, x: CGFloat, y: CGFloat, w: CGFloat, action: Selector) {
            let b = NSButton(checkboxWithTitle: s, target: self, action: action)
            b.state = on ? .on : .off
            b.frame = NSRect(x: x, y: y, width: w, height: 20)
            b.autoresizingMask = [.minYMargin]
            addSubview(b)
        }
        func button(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, action: Selector) {
            let b = NSButton(title: s, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.frame = NSRect(x: x, y: y, width: w, height: 24)
            b.autoresizingMask = [.minYMargin, .minXMargin]
            addSubview(b)
        }

        // 1. 搜索范围
        label("搜索范围", x: pad, y: y, w: 80)
        label("默认是整个主目录；系统应用目录会单独搜索", x: pad + 70, y: y + 1, w: W - pad * 2 - 70,
              size: 11, secondary: true)
        let listH: CGFloat = 66
        y -= listH + 6
        let scroll = NSScrollView(frame: NSRect(x: pad, y: y, width: W - pad * 2 - 64, height: listH))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.minYMargin, .width]
        let col = NSTableColumn(identifier: .init("scope"))
        col.width = scroll.contentSize.width
        scopeTable.addTableColumn(col)
        scopeTable.headerView = nil
        scopeTable.rowHeight = 20
        scopeTable.dataSource = self
        scopeTable.delegate = self
        scroll.documentView = scopeTable
        addSubview(scroll)
        button("添加…", x: W - pad - 58, y: y + listH - 24, w: 58, action: #selector(addScope))
        button("移除", x: W - pad - 58, y: y + listH - 52, w: 58, action: #selector(removeScope))
        y -= 34

        // 2. 排除规则
        label("排除的文件夹", x: pad, y: y, w: 100)
        label("逗号分隔；以 / 或 ~ 开头为路径，否则按文件夹名匹配", x: pad + 90, y: y + 1, w: W - pad * 2 - 90,
              size: 11, secondary: true)
        y -= 28
        setupField(excludeField, value: Self.join(FileSearchSettings.excludes),
                   placeholder: "~/Library, node_modules", frame: NSRect(x: pad, y: y, width: W - pad * 2 - 64, height: 22))
        button("默认", x: W - pad - 58, y: y - 1, w: 58, action: #selector(resetExcludes))
        y -= 30
        label("排除的扩展名", x: pad, y: y + 3, w: 90)
        setupField(extField, value: Self.join(FileSearchSettings.excludedExts),
                   placeholder: "例如 log, tmp", frame: NSRect(x: pad + 90, y: y, width: W - pad * 2 - 154, height: 22))
        y -= 40

        // 3. 选项
        let colW = (W - pad * 2) / 2
        let x2 = pad + colW
        checkbox("搜索应用程序", on: FileSearchSettings.searchApps, x: pad, y: y, w: colW,
                 action: #selector(toggleApps(_:)))
        checkbox("正文搜索时显示命中片段", on: FileSearchSettings.snippets, x: x2, y: y, w: colW,
                 action: #selector(toggleSnippets(_:)))
        y -= 26
        checkbox("在右侧显示文件预览", on: FileSearchSettings.preview, x: pad, y: y, w: colW,
                 action: #selector(togglePreview(_:)))
        checkbox("浏览文件夹时显示隐藏文件", on: FileSearchSettings.showHidden, x: x2, y: y, w: colW,
                 action: #selector(toggleHidden(_:)))
        y -= 26
        checkbox("启用 open / find 关键字", on: FileSearchSettings.openFindKeywords, x: pad, y: y, w: colW,
                 action: #selector(toggleOpenFind(_:)))
        checkbox("启用 tags 关键字（按标签搜）", on: FileSearchSettings.tagsKeyword, x: x2, y: y, w: colW,
                 action: #selector(toggleTags(_:)))
        y -= 38

        // 4. 结果数 + 使用记录
        label("最多显示", x: pad, y: y + 2, w: 70)
        let p = NSPopUpButton(frame: NSRect(x: pad + 66, y: y - 2, width: 100, height: 26), pullsDown: false)
        for n in FileSearchSettings.maxResultChoices { p.addItem(withTitle: "\(n) 条"); p.lastItem?.tag = n }
        if p.selectItem(withTag: FileSearchSettings.maxResults) == false { p.selectItem(at: 1) }
        p.target = self
        p.action = #selector(changeMax(_:))
        p.autoresizingMask = [.minYMargin]
        addSubview(p)
        let clear = NSButton(title: "清除使用记录…", target: self, action: #selector(clearUsage))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: x2 - 6, y: y - 3, width: 130, height: 28)
        clear.autoresizingMask = [.minYMargin]
        addSubview(clear)
        y -= 20
        label("常选的结果会排到前面；清除后重新开始学习", x: x2, y: y - 4, w: colW, size: 11, secondary: true)
        y -= 40

        // 翻页键
        label("向上翻页", x: pad, y: y + 2, w: 70)
        pageUpField = makePageField(x: pad + 66, y: y - 2, binding: FileSearchSettings.pageUpKey) {
            FileSearchSettings.pageUpKey = $0
        }
        label("向下翻页", x: x2, y: y + 2, w: 70)
        pageDownField = makePageField(x: x2 + 66, y: y - 2, binding: FileSearchSettings.pageDownKey) {
            FileSearchSettings.pageDownKey = $0
        }
        button("恢复默认", x: W - pad - 70, y: y - 1, w: 70, action: #selector(resetPageKeys))
        y -= 38
        let pageHint = NSTextField(wrappingLabelWithString:
            "点一下输入框再按键，⌫ 清除。没有 PageUp / PageDown 键的键盘可以用 fn+↑ / fn+↓，或设成 ⌘[ 这类组合。")
        pageHint.font = NSFont.systemFont(ofSize: 11)
        pageHint.textColor = .secondaryLabelColor
        pageHint.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 32)
        pageHint.autoresizingMask = [.minYMargin, .width]
        addSubview(pageHint)

        // 5. 用法提示
        let tip = NSTextField(wrappingLabelWithString:
            "用法：直接输入搜索应用和文件；输入框为空时按空格（变成 '）搜索文件夹；「in 关键词」搜正文；"
            + "以 / 或 ~ 开头浏览文件夹；⏎ 打开，⌘⏎ 打开所在目录；→ 或 ⌘K 操作菜单；⌥↓ 加入已选文件；⌘1–9 网页 / AI 搜索。")
        tip.font = NSFont.systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.frame = NSRect(x: pad, y: 12, width: W - pad * 2, height: 32)
        tip.autoresizingMask = [.maxYMargin, .width]
        addSubview(tip)
    }

    private func makePageField(x: CGFloat, y: CGFloat, binding: HotkeyBinding,
                              onChange: @escaping (HotkeyBinding) -> Void) -> HotkeyRecorderField {
        let f = HotkeyRecorderField(frame: NSRect(x: x, y: y, width: 110, height: 26))
        f.allowsFunctionKeyAlone = true
        f.binding = binding
        f.onChange = onChange
        f.autoresizingMask = [.minYMargin]
        addSubview(f)
        return f
    }

    @objc private func resetPageKeys() {
        FileSearchSettings.pageUpKey = FileSearchSettings.defaultPageUp
        FileSearchSettings.pageDownKey = FileSearchSettings.defaultPageDown
        pageUpField?.binding = FileSearchSettings.defaultPageUp
        pageDownField?.binding = FileSearchSettings.defaultPageDown
    }

    private func setupField(_ f: NSTextField, value: String, placeholder: String, frame: NSRect) {
        f.stringValue = value
        f.placeholderString = placeholder
        f.font = NSFont.systemFont(ofSize: 12)
        f.frame = frame
        f.autoresizingMask = [.minYMargin, .width]
        f.delegate = self
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        addSubview(f)
    }

    // MARK: 文本框
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let list = Self.split(f.stringValue)
        if f === excludeField {
            if list != FileSearchSettings.excludes { FileSearchSettings.excludes = list }
        } else if f === extField {
            let exts = list.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
                .filter { !$0.isEmpty }
            if exts != FileSearchSettings.excludedExts { FileSearchSettings.excludedExts = exts }
            f.stringValue = Self.join(exts)
            return
        }
        f.stringValue = Self.join(list)
    }

    // MARK: 动作
    @objc private func toggleApps(_ s: NSButton) { FileSearchSettings.searchApps = s.state == .on }
    @objc private func toggleSnippets(_ s: NSButton) { FileSearchSettings.snippets = s.state == .on }
    @objc private func togglePreview(_ s: NSButton) { FileSearchSettings.preview = s.state == .on }
    @objc private func toggleHidden(_ s: NSButton) { FileSearchSettings.showHidden = s.state == .on }
    @objc private func toggleOpenFind(_ s: NSButton) { FileSearchSettings.openFindKeywords = s.state == .on }
    @objc private func toggleTags(_ s: NSButton) { FileSearchSettings.tagsKeyword = s.state == .on }
    @objc private func changeMax(_ s: NSPopUpButton) { FileSearchSettings.maxResults = s.selectedTag() }

    @objc private func resetExcludes() {
        FileSearchSettings.excludes = FileSearchSettings.defaultExcludes
        excludeField.stringValue = Self.join(FileSearchSettings.defaultExcludes)
    }

    @objc private func addScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "添加"
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let self = self else { return }
            for url in panel.urls {
                let p = FileSearchSettings.abbreviate(url.path)
                if !self.scopes.contains(p) { self.scopes.append(p) }
            }
            FileSearchSettings.scopes = self.scopes
            self.scopeTable.reloadData()
        }
    }

    @objc private func removeScope() {
        let rows = scopeTable.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        let rest = scopes.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        guard !rest.isEmpty else {
            ScreenshotToast.show("至少保留一个搜索范围")
            return
        }
        scopes = rest
        FileSearchSettings.scopes = scopes
        scopeTable.reloadData()
    }

    @objc private func clearUsage() {
        let alert = NSAlert()
        alert.messageText = "清除文件搜索的使用记录？"
        alert.informativeText = "结果排序会恢复为默认，不影响任何文件。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { resp in
            if resp == .alertFirstButtonReturn {
                FileSearchUsage.shared.clear()
                FileSearchUsage.shared.flush()
            }
        }
    }

    // MARK: 搜索范围列表
    func numberOfRows(in tableView: NSTableView) -> Int { scopes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = scopes[row]
        let path = FileSearchSettings.expand(s)
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 20))
        let iv = NSImageView(frame: NSRect(x: 4, y: 2, width: 16, height: 16))
        iv.image = NSWorkspace.shared.icon(forFile: path)
        let tf = NSTextField(labelWithString: s == "~" ? "~（主目录）" : s)
        tf.frame = NSRect(x: 26, y: 2, width: tableView.bounds.width - 30, height: 16)
        tf.lineBreakMode = .byTruncatingMiddle
        tf.autoresizingMask = [.width]
        tf.toolTip = path
        if !FileSearchSettings.isDirectory(path) {
            tf.stringValue += "（不存在）"
            tf.textColor = .secondaryLabelColor
        }
        cell.addSubview(iv)
        cell.addSubview(tf)
        return cell
    }
}
