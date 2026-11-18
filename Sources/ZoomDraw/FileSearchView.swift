import AppKit
import CoreServices

/// 文件搜索的内容：搜索框 + 已选文件 + 结果列表 + 底部提示；也承载 ⌘1–9 的 AI / 网页模板和 AI 回答
final class FileSearchView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?
    var onWebSearch: ((WebSearchEngine, String) -> Void)?
    var onPasteText: ((String) -> Void)?
    var onPin: ((AIConversation) -> Void)?
    var onOpenAISettings: (() -> Void)?
    var onOpenPrefs: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onChooseFolder: ((String, @escaping (URL?) -> Void) -> Void)?

    static let headerH: CGFloat = 58
    static let bufferH: CGFloat = 36
    static let footerH: CGFloat = 52
    static let rowH: CGFloat = 50
    static let snippetRowH: CGFloat = 68
    static let aiHeight: CGFloat = 680
    private static let maxRows = 8
    private static let maxSnippetRows = 6

    let searchField = NSTextField()
    private let bg = NSVisualEffectView()
    private let headerIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let headSep = NSView()
    private let bufferBar = NSView()
    private let bufferLabel = NSTextField(labelWithString: "")
    private var bufferIcons: [NSImageView] = []
    private let scrollView = NSScrollView()
    private let tableView = FileResultTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footSep = NSView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let webBar = NSTextField(labelWithString: "")
    private let previewPane = FilePreviewPane()

    private enum Mode {
        case search
        case actions(targets: [URL], isBuffer: Bool)
        case openWith(URL)
        case destinations(targets: [URL], move: Bool, isBuffer: Bool)
        case rename(URL)
        case aiHistory
    }
    private struct Saved {
        let mode: Mode
        let text: String
        let items: [SearchItem]
        let subItems: [SearchItem]
        let row: Int
    }
    private var mode: Mode = .search
    private var stack: [Saved] = []
    private var items: [SearchItem] = []
    private var subItems: [SearchItem] = []
    private(set) var buffer: [URL] = []

    private var query: ParsedQuery = .empty
    private var queryText = ""
    private let spotlight = SpotlightRunner()
    private var searching = false
    private var debounce: DispatchWorkItem?
    private var appItems: [SearchItem] = []
    private struct Candidate {
        let path: String
        var score: Int
        var ranges: [NSRange]
        var isDir: Bool?
    }
    private var candidates: [String: Candidate] = [:]
    private var mergedHits = 0
    /// 每次重新搜索 / 关闭时 +1，后台打分的旧结果据此丢弃
    private var searchGen = 0
    private static let scoreQueue = DispatchQueue(label: "zoomdraw.filesearch.score", qos: .userInitiated)

    /// 打分所需的全部输入（值类型副本），可以在后台线程使用
    private struct ScoreContext {
        let query: ParsedQuery
        let queryText: String
        let usage: [String: FileSearchUsage.Entry]
        let home: String

        private var isContent: Bool { if case .content = query { return true }; return false }

        func score(path: String) -> (score: Int, ranges: [NSRange])? {
            let name = (path as NSString).lastPathComponent
            var s: Int
            var ranges: [NSRange] = []
            switch query {
            case .name(let tokens, _, _), .folders(let tokens):
                if let m = NameMatcher.match(name, tokens: tokens, stem: (name as NSString).deletingPathExtension) {
                    s = m.score; ranges = m.ranges
                } else {
                    s = 450
                }
            case .content(let tokens):
                s = 500
                if let m = NameMatcher.match(name, tokens: tokens) { s += 150; ranges = m.ranges }
            case .tags:
                s = 500
            default:
                return nil
            }
            s += FileSearchUsage.boost(usage, path: path, query: queryText)
            let rel = path.hasPrefix(home) ? path.dropFirst(home.count) : Substring(path)
            s -= min(rel.filter { $0 == "/" }.count * 3, 45)
            return (s, ranges)
        }

        /// 最近使用（正文搜索时用修改时间）的加成；需要读文件属性，较慢，只对少量结果调用
        func recencyBonus(path: String) -> Int {
            var date: Date?
            if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
                date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            }
            if date == nil, isContent {
                date = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            guard let d = date else { return 0 }
            let age = Date().timeIntervalSince(d)
            return age < 86400 ? 80 : age < 7 * 86400 ? 50 : age < 30 * 86400 ? 25 : age < 365 * 86400 ? 5 : 0
        }
    }
    private var appPaths = Set<String>()
    private var pendingSelectURL: URL?
    private var userMovedSelection = false
    private var snippets: [String: FileSnippet.Result?] = [:]
    private var lastTrash: (map: [URL: URL], at: Date)?
    private let iconCache = NSCache<NSString, NSImage>()

    private(set) var isAIMode = false
    private var aiView: AIResultView?
    private(set) var conversation: AIConversation?

    private static let placeholder = "搜索应用和文件　空格 搜文件夹　in 搜正文"
    private static let aiPlaceholder = "继续追问…（⏎ 发送；输入框为空时 ⏎ 粘贴回答）"

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(updateWebBar), name: .webSearchChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(aiHistoryChanged), name: .aiHistoryChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var isSearchMode: Bool { if case .search = mode { return true }; return false }
    private var isBrowsing: Bool { if case .browse = query, isSearchMode { return true }; return false }
    private var isContentQuery: Bool { if case .content = query { return true }; return false }
    private var isFolderQuery: Bool { if case .folders = query { return true }; return false }
    private var showsList: Bool { !isSearchMode || !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: 构建

    private func build() {
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(bg)

        headerIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        headerIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        headerIcon.contentTintColor = .secondaryLabelColor
        bg.addSubview(headerIcon)

        searchField.font = NSFont.systemFont(ofSize: 21, weight: .regular)
        searchField.placeholderString = Self.placeholder
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        bg.addSubview(searchField)

        statusLabel.alignment = .right
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        bg.addSubview(statusLabel)

        for s in [headSep, footSep] {
            s.wantsLayer = true
            s.layer?.backgroundColor = NSColor.separatorColor.cgColor
            bg.addSubview(s)
        }

        bufferLabel.font = NSFont.systemFont(ofSize: 11.5)
        bufferLabel.textColor = .secondaryLabelColor
        bufferLabel.lineBreakMode = .byTruncatingTail
        bufferBar.addSubview(bufferLabel)
        bufferBar.wantsLayer = true
        bufferBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        bg.addSubview(bufferBar)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let col = NSTableColumn(identifier: .init("item"))
        col.width = FileSearchController.width - 4
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = Self.rowH
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
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
        tableView.onRightClick = { [weak self] row in self?.rowRightClicked(row) }
        scrollView.documentView = tableView
        bg.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 2
        bg.addSubview(emptyLabel)

        hintLabel.font = Self.hintFont
        hintLabel.lineBreakMode = .byTruncatingTail
        bg.addSubview(hintLabel)
        webBar.lineBreakMode = .byTruncatingTail
        bg.addSubview(webBar)
        previewPane.isHidden = true
        bg.addSubview(previewPane)
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        bg.frame = bounds
        var y = H - Self.headerH
        headerIcon.frame = NSRect(x: 20, y: y + 18, width: 24, height: 22)
        searchField.frame = NSRect(x: 54, y: y + 14, width: W - 54 - 150, height: 30)
        statusLabel.frame = NSRect(x: W - 146, y: y + 21, width: 128, height: 16)
        headSep.frame = NSRect(x: 0, y: y, width: W, height: 1)
        headSep.isHidden = !(showsList || !buffer.isEmpty || isAIMode)

        bufferBar.isHidden = buffer.isEmpty || isAIMode
        if !bufferBar.isHidden {
            y -= Self.bufferH
            bufferBar.frame = NSRect(x: 0, y: y, width: W, height: Self.bufferH)
            var x: CGFloat = 18
            for iv in bufferIcons {
                iv.frame = NSRect(x: x, y: 8, width: 20, height: 20)
                x += 24
            }
            bufferLabel.frame = NSRect(x: x + 6, y: 10, width: W - x - 24, height: 16)
        }

        let footerVisible = showsList || isAIMode
        footSep.isHidden = !footerVisible
        hintLabel.isHidden = !footerVisible
        webBar.isHidden = !footerVisible
        footSep.frame = NSRect(x: 0, y: Self.footerH, width: W, height: 1)
        hintLabel.frame = NSRect(x: 16, y: 29, width: W - 32, height: 17)
        webBar.frame = NSRect(x: 16, y: 8, width: W - 32, height: 17)

        let fullRect = NSRect(x: 0, y: Self.footerH + 1, width: W, height: max(0, y - Self.footerH - 1))
        let showPreview = previewVisible
        previewPane.isHidden = !showPreview
        var listRect = fullRect
        if showPreview {
            let pw = FilePreviewPane.width
            listRect.size.width = W - pw
            previewPane.frame = NSRect(x: W - pw, y: fullRect.minY, width: pw, height: fullRect.height)
        }
        scrollView.frame = listRect
        scrollView.isHidden = isAIMode || !showsList
        if let col = tableView.tableColumns.first, abs(col.width - (listRect.width - 4)) > 0.5 {
            col.width = listRect.width - 4
        }
        aiView?.frame = fullRect
        emptyLabel.frame = NSRect(x: 30, y: fullRect.midY - 20, width: W - 60, height: 40)
    }

    // MARK: 右侧预览

    /// 要预览的文件：搜索结果里选中的那个；操作菜单 / 打开方式 / 目标文件夹 / 重命名时是被操作的文件
    private var previewTarget: URL? {
        guard !isAIMode else { return nil }
        switch mode {
        case .search:
            return selectedItem?.fileURL
        case .actions(let t, _), .destinations(let t, _, _):
            return t.count == 1 ? t[0] : nil
        case .openWith(let u), .rename(let u):
            return u
        case .aiHistory:
            return nil
        }
    }

    private var previewVisible: Bool {
        FileSearchSettings.preview && showsList && !items.isEmpty && previewTarget != nil
    }

    private func updatePreview() {
        previewPane.show(FileSearchSettings.preview ? previewTarget : nil)
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        if isAIMode { return Self.aiHeight }
        var h = Self.headerH
        if !buffer.isEmpty { h += Self.bufferH }
        if showsList { h += listHeight + 1 + Self.footerH }
        return h
    }

    private var listHeight: CGFloat {
        guard !items.isEmpty else { return 72 }
        let limit = isContentQuery && FileSearchSettings.snippets ? Self.maxSnippetRows : Self.maxRows
        var total: CGFloat = 0
        for i in 0..<min(items.count, limit) { total += rowHeight(i) }
        total += 6
        // 右侧有预览时，结果少也要留够预览的高度
        if FileSearchSettings.preview && previewTarget != nil { total = max(total, 340) }
        return total
    }

    private func rowHeight(_ row: Int) -> CGFloat {
        row < items.count && items[row].contentHit ? Self.snippetRowH : Self.rowH
    }

    private func refreshChrome() {
        updateStatus()
        updateHints()
        updateWebBar()
        updateEmpty()
        updatePreview()
        needsLayout = true
        onHeightChanged?(preferredHeight)
    }

    // MARK: 打开 / 关闭

    func prepareForShow() {
        if isAIMode { exitAI(reload: false) }
        stack = []
        mode = .search
        buffer = []
        rebuildBufferBar()
        spotlight.stop()
        searchGen += 1
        debounce?.cancel()
        query = .empty
        queryText = ""
        candidates = [:]
        appItems = []
        items = []
        snippets = [:]
        searchField.stringValue = ""
        searchField.placeholderString = Self.placeholder
        tableView.reloadData()
        refreshChrome()
        window?.makeFirstResponder(searchField)
    }

    var canResumeAI: Bool { isAIMode && conversation != nil }

    func prepareForResume() {
        updateWebBar()
        window?.makeFirstResponder(searchField)
    }

    func didHide() {
        spotlight.stop()
        searchGen += 1
        debounce?.cancel()
        searching = false
    }

    func moveCursorToEnd() {
        if let ed = searchField.currentEditor() {
            ed.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
    }

    private func setText(_ s: String) {
        searchField.stringValue = s
        window?.makeFirstResponder(searchField)
        moveCursorToEnd()
        textChanged(immediate: true)
    }

    // MARK: 搜索

    func controlTextDidChange(_ obj: Notification) {
        textChanged(immediate: false)
    }

    private func textChanged(immediate: Bool) {
        guard !isAIMode else { return }
        userMovedSelection = false
        switch mode {
        case .search:
            debounce?.cancel()
            if immediate || { if case .browse = ParsedQuery.parse(searchField.stringValue) { return true }; return false }() {
                runSearch()
            } else {
                let w = DispatchWorkItem { [weak self] in self?.runSearch() }
                debounce = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: w)
            }
        case .actions, .openWith, .destinations:
            filterSubItems()
        case .aiHistory:
            reloadHistory()
        case .rename:
            break
        }
    }

    private func runSearch() {
        spotlight.stop()
        searchGen += 1
        searching = false
        queryText = searchField.stringValue
        query = ParsedQuery.parse(queryText)
        candidates = [:]
        appItems = []
        appPaths = []
        mergedHits = 0
        snippets = [:]

        switch query {
        case .empty, .hint:
            setItems([])
        case .browse(let dir, let filter):
            setItems(browseItems(dir: dir, filter: filter))
        case .name(let tokens, let apps, _):
            if apps { appItems = makeAppItems(tokens) }
            appPaths = Set(appItems.compactMap { $0.url?.path })
            addLocalCandidates(tokens, memory: true)
            rebuildResults()
            startSpotlight(.name, tokens: tokens, cap: 3000, budget: 2.0)
        case .content(let tokens):
            rebuildResults()
            startSpotlight(.content, tokens: tokens, cap: 800, budget: 6.0)
        case .tags(let tokens):
            rebuildResults()
            startSpotlight(.tags, tokens: tokens, cap: 800, budget: 3.0)
        case .folders(let tokens):
            addLocalCandidates(tokens, memory: true)
            rebuildResults()
            startSpotlight(.folders, tokens: tokens, cap: 3000, budget: 2.0)
        }
    }

    private func startSpotlight(_ m: SpotlightRunner.Mode, tokens: [String], cap: Int, budget: TimeInterval) {
        let roots = SearchRoots.current().roots
        guard !roots.isEmpty else { refreshChrome(); return }
        searching = true
        updateStatus()
        let rules = ExclusionRules.current
        let ctx = scoreContext()
        let skip = appPaths
        let gen = searchGen
        spotlight.start(m, tokens: tokens, roots: roots, cap: cap, budget: budget) { [weak self] hits, done in
            guard let self = self, gen == self.searchGen else { return }
            // 新增的结果在后台线程过滤、打分（3000 条约 100ms+，放在主线程会卡住输入），主线程只合并和刷新列表
            let start = min(self.mergedHits, hits.count)
            let fresh = Array(hits[start...])
            self.mergedHits = hits.count
            Self.scoreQueue.async {
                var scored: [Candidate] = []
                for h in fresh {
                    if skip.contains(h.path) || rules.excludes(path: h.path) { continue }
                    if let r = ctx.score(path: h.path) {
                        scored.append(Candidate(path: h.path, score: r.score, ranges: r.ranges))
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, gen == self.searchGen else { return }
                    for c in scored where self.candidates[c.path] == nil { self.candidates[c.path] = c }
                    if done {
                        self.searching = false
                        self.applyRecency(ctx: ctx, gen: gen)
                    }
                    self.rebuildResults()
                }
            }
        }
    }

    /// 「最近使用 / 修改」加成：只对排在前面的几十条补读时间（逐条读取很慢），读完后微调排序
    private func applyRecency(ctx: ScoreContext, gen: Int) {
        let n = FileSearchSettings.maxResults + 20
        let top = candidates.values.sorted { $0.score > $1.score }.prefix(n).map(\.path)
        guard !top.isEmpty else { return }
        Self.scoreQueue.async {
            var bonus: [(String, Int)] = []
            for p in top {
                let b = ctx.recencyBonus(path: p)
                if b > 0 { bonus.append((p, b)) }
            }
            guard !bonus.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, gen == self.searchGen else { return }
                for (p, b) in bonus { self.candidates[p]?.score += b }
                self.rebuildResults()
            }
        }
    }

    /// 不在 Spotlight 范围里、但应该能搜到的：搜索范围根目录下的条目、使用记忆里的文件
    private func addLocalCandidates(_ tokens: [String], memory: Bool) {
        let rules = ExclusionRules.current
        let fm = FileManager.default
        for dir in SearchRoots.current().loose {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                guard tokens.allSatisfy({ name.range(of: $0, options: NameMatcher.opts) != nil }) else { continue }
                let p = (dir as NSString).appendingPathComponent(name)
                if rules.excludes(path: p) || appPaths.contains(p) { continue }
                if isFolderQuery && !FileSearchSettings.isDirectory(p) { continue }
                if let c = score(path: p) { candidates[p] = c }
            }
        }
        guard memory else { return }
        for p in FileSearchUsage.shared.candidates(tokens: tokens)
        where candidates[p] == nil && !appPaths.contains(p) && fm.fileExists(atPath: p) && !p.contains("/.Trash/")
            && (!isFolderQuery || FileSearchSettings.isDirectory(p)) {
            if let c = score(path: p) { candidates[p] = c }
        }
    }

    private func scoreContext() -> ScoreContext {
        ScoreContext(query: query, queryText: queryText, usage: FileSearchUsage.shared.entries,
                     home: NSHomeDirectory())
    }

    private func score(path: String) -> Candidate? {
        guard let r = scoreContext().score(path: path) else { return nil }
        return Candidate(path: path, score: r.score, ranges: r.ranges)
    }

    private func rebuildResults() {
        let limit = FileSearchSettings.maxResults
        let sorted = candidates.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let fm = FileManager.default
        var fileItems: [SearchItem] = []
        for var c in sorted {
            if fileItems.count >= limit { break }
            guard fm.fileExists(atPath: c.path) else { continue }
            if c.isDir == nil {
                c.isDir = FileSearchSettings.isDirectory(c.path) && !NSWorkspace.shared.isFilePackage(atPath: c.path)
                candidates[c.path] = c
            }
            if isFolderQuery && c.isDir != true { continue }
            let url = URL(fileURLWithPath: c.path)
            let kind: SearchItem.Kind = url.pathExtension.lowercased() == "app" ? .app : .file
            var it = SearchItem(kind: kind, url: url, title: url.lastPathComponent,
                                subtitle: FileSearchSettings.abbreviate(url.deletingLastPathComponent().path),
                                titleRanges: c.ranges, isDirectory: c.isDir ?? false)
            it.contentHit = isContentQuery && FileSearchSettings.snippets
            fileItems.append(it)
        }
        setItems(appItems + fileItems)
    }

    private func makeAppItems(_ tokens: [String]) -> [SearchItem] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        let scored = AppCatalog.shared.search(tokens: tokens).map { app, m -> (AppCatalog.App, NameMatch, Int) in
            var s = m.score + FileSearchUsage.shared.boost(path: app.url.path, query: queryText)
            if running.contains(app.url.path) { s += 15 }
            return (app, m, s)
        }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.name.count < $1.0.name.count }
        return scored.prefix(8).map { app, m, _ in
            var sub = "应用程序"
            if running.contains(app.url.path) { sub += " · 运行中" }
            sub += " · " + FileSearchSettings.abbreviate(app.url.deletingLastPathComponent().path)
            return SearchItem(kind: .app, url: app.url, title: app.name, subtitle: sub, titleRanges: m.ranges)
        }
    }

    private func browseItems(dir: String, filter: String) -> [SearchItem] {
        guard FileSearchSettings.isDirectory(dir) else { return [] }
        let url = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        let opts: FileManager.DirectoryEnumerationOptions = FileSearchSettings.showHidden ? [] : [.skipsHiddenFiles]
        let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)) ?? []
        let tokens = ParsedQuery.split(filter)
        var scored: [(SearchItem, Int)] = []
        for k in kids {
            let name = k.lastPathComponent
            var s = 0
            var ranges: [NSRange] = []
            if !tokens.isEmpty {
                guard let m = NameMatcher.match(name, tokens: tokens, stem: (name as NSString).deletingPathExtension) else { continue }
                s = m.score; ranges = m.ranges
            }
            let v = try? k.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true && v?.isPackage != true
            var parts: [String] = [isDir ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)]
            if let d = v?.contentModificationDate { parts.append("修改于 " + ClipboardHistoryView.relativeTime(d)) }
            let kind: SearchItem.Kind = k.pathExtension.lowercased() == "app" ? .app : .file
            scored.append((SearchItem(kind: kind, url: k, title: name, subtitle: parts.joined(separator: " · "),
                                      titleRanges: ranges, isDirectory: isDir), s))
        }
        if tokens.isEmpty {
            scored.sort { $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
        } else {
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
        }
        var out = scored.prefix(1000).map(\.0)
        if tokens.isEmpty {
            let name = dir == "/" ? "/" : FileManager.default.displayName(atPath: dir)
            var cur = SearchItem(kind: .file, url: url, title: name, subtitle: "当前文件夹 · " + FileSearchSettings.abbreviate(dir),
                                 isDirectory: true)
            cur.isCurrentFolder = true
            out.insert(cur, at: 0)
        }
        return out
    }

    // MARK: 列表

    private func setItems(_ new: [SearchItem]) {
        let prev = selectedItem?.url
        items = new
        tableView.reloadData()
        var row = 0
        if let p = pendingSelectURL?.standardizedFileURL, let i = items.firstIndex(where: { $0.url?.standardizedFileURL == p }) {
            row = i
            pendingSelectURL = nil
            userMovedSelection = true
        } else if userMovedSelection, let p = prev, let i = items.firstIndex(where: { $0.url == p }) {
            row = i
        }
        if items.isEmpty { tableView.deselectAll(nil) } else { select(row: row) }
        refreshChrome()
    }

    private var selectedItem: SearchItem? {
        let r = tableView.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    private func select(row: Int) {
        guard !items.isEmpty else { return }
        let r = max(0, min(items.count - 1, row))
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    /// 按下的是翻页键时返回 -1（上一页）/ 1（下一页）
    private func pageDirection(_ e: NSEvent, mods: NSEvent.ModifierFlags) -> Int? {
        func match(_ b: HotkeyBinding) -> Bool {
            !b.isNone && b.keyCode == UInt32(e.keyCode) && b.modifierFlags.intersection([.command, .option, .control, .shift]) == mods
        }
        if match(FileSearchSettings.pageUpKey) { return -1 }
        if match(FileSearchSettings.pageDownKey) { return 1 }
        return nil
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        userMovedSelection = true
        let r = tableView.selectedRow
        select(row: r < 0 ? 0 : r + delta)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileResultCell) ?? {
            let c = FileResultCell(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: Self.rowH))
            c.identifier = id
            return c
        }()
        let item = items[row]
        var snippet: FileSnippet.Result?? = nil
        if item.contentHit, let url = item.url {
            if let s = snippets[url.path] {
                snippet = .some(s)
            } else {
                let tokens = query.tokens
                let path = url.path
                FileSnippet.load(url, tokens: tokens) { [weak self] r in
                    guard let self = self, self.isContentQuery else { return }
                    self.snippets.updateValue(r, forKey: path)
                    if let i = self.items.firstIndex(where: { $0.url?.path == path }) {
                        self.tableView.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
        }
        let inBuffer = item.fileURL.map { u in buffer.contains(u) } ?? false
        cell.configure(item, index: row, icon: icon(for: item), snippet: snippet, inBuffer: inBuffer)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count, let u = items[row].fileURL else { return nil }
        return u as NSURL
    }

    private func icon(for item: SearchItem) -> NSImage? {
        if let s = item.symbol { return NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        guard let u = item.url else { return nil }
        let key = u.path as NSString
        if let img = iconCache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: u.path)
        iconCache.setObject(img, forKey: key)
        return img
    }

    @objc private func rowClicked() {
        userMovedSelection = true
        window?.makeFirstResponder(searchField)
        moveCursorToEnd()
    }

    @objc private func rowDoubleClicked() {
        let r = tableView.clickedRow
        guard r >= 0, r < items.count else { return }
        activate(items[r], alternate: false)
    }

    private func rowRightClicked(_ row: Int) {
        guard row < items.count else { return }
        select(row: row)
        userMovedSelection = true
        if let u = items[row].fileURL, isSearchMode { showActions([u], isBuffer: false) }
    }

    // MARK: 状态与提示

    private func updateStatus() {
        if isAIMode {
            statusLabel.stringValue = conversation.map { "✦ " + $0.engine.name } ?? ""
            return
        }
        switch mode {
        case .search:
            let files = items.filter { $0.kind == .file && !$0.isCurrentFolder }.count
            let apps = items.filter { $0.kind == .app }.count
            var parts: [String] = []
            if case .content = query { parts.append("正文") }
            if case .tags = query { parts.append("标签") }
            if isFolderQuery { parts.append("文件夹") }
            if apps > 0, !isBrowsing { parts.append("应用 \(apps)") }
            if files > 0 || !isBrowsing && apps == 0 && !items.isEmpty { parts.append(isBrowsing ? "\(files) 项" : isFolderQuery ? "\(files) 个" : "文件 \(files)") }
            if isBrowsing, items.count > 1 { parts = ["\(items.count - 1) 项"] }
            if searching { parts.append("搜索中…") }
            statusLabel.stringValue = parts.joined(separator: " · ")
        case .actions: statusLabel.stringValue = "操作"
        case .openWith: statusLabel.stringValue = "打开方式"
        case .destinations(_, let move, _): statusLabel.stringValue = move ? "移动到" : "复制到"
        case .rename: statusLabel.stringValue = "重命名"
        case .aiHistory: statusLabel.stringValue = "✦ AI 历史 · \(AIHistoryStore.shared.sessions.count)"
        }
    }

    private func updateEmpty() {
        guard items.isEmpty, showsList, !isAIMode else { emptyLabel.isHidden = true; return }
        emptyLabel.isHidden = false
        switch mode {
        case .search:
            switch query {
            case .hint(let h):
                emptyLabel.stringValue = h
            case .browse(let dir, let filter):
                emptyLabel.stringValue = !FileSearchSettings.isDirectory(dir) ? "文件夹不存在" : filter.isEmpty ? "空文件夹" : "没有匹配的条目"
            default:
                if searching {
                    emptyLabel.stringValue = "搜索中…"
                } else {
                    let q = ParsedQuery.templateText(searchField.stringValue)
                    let shown = q.count > 20 ? String(q.prefix(20)) + "…" : q
                    var s = isContentQuery ? "没有正文包含“\(shown)”的文件" : isFolderQuery ? "没有找到匹配的文件夹" : "没有找到匹配的应用或文件"
                    if let first = WebSearch.shortcutEngines.first { s += "\n按 ⌘1 用「\(first.name)」搜索“\(shown)”" }
                    emptyLabel.stringValue = s
                }
            }
        case .aiHistory:
            if !AISettings.historyEnabled { emptyLabel.stringValue = "AI 历史已关闭\n可在「偏好设置 → AI」中开启" }
            else if AIHistoryStore.shared.sessions.isEmpty { emptyLabel.stringValue = "还没有 AI 记录\n输入问题后按 ⌘1–9 使用 AI 搜索或 AI 指令" }
            else { emptyLabel.stringValue = "没有匹配的 AI 记录" }
        default:
            emptyLabel.stringValue = "没有匹配的项目"
        }
    }

    // 底部两行提示（操作快捷键、⌘1–9 快捷搜索）共用同一套样式：按键醒目、说明稍淡，不再区分蓝色
    private static let hintFont = HintText.font

    private func styledHints(prefix: String? = nil, _ pairs: [(String, String)]) -> NSAttributedString {
        HintText.make(prefix: prefix, pairs)
    }

    private func updateHints() {
        var pairs: [(String, String)]
        if isAIMode {
            let verb = ClipboardSettings.autoPaste ? "粘贴" : "复制"
            pairs = [("⏎", "追问 / 输入框为空时\(verb)回答"), ("⇧⏎", "\(verb) Markdown"), ("⌘C", "复制"),
                     ("⌘P", "钉住窗口"), ("⌘R", "重新生成"), ("⌘S", "存入暂存板"), ("Esc", "停止 / 返回")]
        } else {
            switch mode {
            case .search where isBrowsing:
                pairs = [("⏎", "打开"), ("⌘⏎", "打开所在目录"), ("→", "进入 / 操作"), ("←", "上一级"), ("Tab", "补全"),
                         ("⌥↓", "加入已选"), ("Esc", "关闭")]
            case .search:
                pairs = [("⏎", "打开"), ("⌘⏎", "打开所在目录"), ("→", "操作"), ("⌥↓", "加入已选"),
                         ("⌘C", "复制路径"), ("⌥⌘C", "复制文件"), ("⌘H", "AI 历史"), ("Esc", "关闭")]
            case .actions, .openWith, .destinations:
                pairs = [("⏎", "执行"), ("输入文字", "筛选"), ("⌥1–9", "直接执行"), ("Esc", "返回")]
            case .rename:
                pairs = [("⏎", "确认重命名"), ("Esc", "取消")]
            case .aiHistory:
                pairs = [("⏎", "打开"), ("⌥1–9", "粘贴回答"), ("⌘C", "复制回答"), ("⌘P", "钉住窗口"),
                         ("⌘⌫", "删除"), ("⌘S", "存入暂存板"), ("Esc", "返回")]
            }
            if case .search = mode, let t = lastTrash, Date().timeIntervalSince(t.at) < 120 {
                pairs.insert(("⌘Z", "撤销删除"), at: pairs.count - 1)
            }
        }
        hintLabel.attributedStringValue = styledHints(pairs)
    }

    /// ⌘1 AI 搜索  ⌘2 百度地图 …
    @objc private func updateWebBar() {
        let engines = WebSearch.shortcutEngines
        let prefix = isAIMode ? "换个方式" : "快捷搜索"
        if engines.isEmpty {
            let out = NSMutableAttributedString(attributedString: styledHints(prefix: prefix, []))
            out.append(NSAttributedString(string: "未启用，可在「偏好设置 → 快捷搜索」中添加", attributes: [
                .font: Self.hintFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            webBar.attributedStringValue = out
        } else {
            webBar.attributedStringValue = styledHints(prefix: prefix, engines.enumerated().map { ("⌘\($0.offset + 1)", $0.element.name) })
        }
        webBar.toolTip = isAIMode
            ? "按 ⌘1–9 用其他模板处理同一个问题；输入框里有内容时处理输入的内容"
            : "按 ⌘1–9 用 AI 或网页搜索输入的内容；输入框为空时处理剪贴板里的内容（图片可用 AI 识别）"
    }

    // MARK: 已选文件（文件缓冲区）

    private func rebuildBufferBar() {
        bufferIcons.forEach { $0.removeFromSuperview() }
        bufferIcons = buffer.prefix(10).map { u in
            let iv = NSImageView()
            iv.image = NSWorkspace.shared.icon(forFile: u.path)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.toolTip = u.path
            bufferBar.addSubview(iv)
            return iv
        }
        let names = buffer.map(\.lastPathComponent).joined(separator: "、")
        bufferLabel.stringValue = buffer.isEmpty ? "" : "已选 \(buffer.count) 个：\(names)    ⌥→ 操作  ⌥← 移除最后一个"
    }

    private func addToBuffer(advance: Bool) {
        guard let u = selectedItem?.fileURL, !(selectedItem?.isCurrentFolder ?? false) || true else { NSSound.beep(); return }
        if !buffer.contains(u) { buffer.append(u) }
        rebuildBufferBar()
        let r = tableView.selectedRow
        tableView.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integer: 0))
        if advance { moveSelection(1) }
        refreshChrome()
    }

    private func removeLastFromBuffer() {
        guard !buffer.isEmpty else { NSSound.beep(); return }
        buffer.removeLast()
        rebuildBufferBar()
        tableView.reloadData()
        refreshChrome()
    }

    // MARK: 子列表（操作 / 打开方式 / 目标文件夹）

    private func push(_ m: Mode) {
        stack.append(Saved(mode: mode, text: searchField.stringValue, items: items, subItems: subItems,
                           row: tableView.selectedRow))
        spotlight.stop()
        debounce?.cancel()
        searching = false
        mode = m
    }

    /// 返回上一层；needsRefresh：列表内容已变化（删除 / 重命名后）需要重新搜索
    private func popState(refresh: Bool = false, select url: URL? = nil) {
        guard let s = stack.popLast() else { onClose?(); return }
        mode = s.mode
        searchField.stringValue = s.text
        searchField.placeholderString = placeholder(for: mode)
        subItems = s.subItems
        if case .search = mode, refresh {
            pendingSelectURL = url
            runSearch()
        } else {
            items = s.items
            tableView.reloadData()
            if !items.isEmpty { select(row: max(0, s.row)) }
            refreshChrome()
        }
        window?.makeFirstResponder(searchField)
        moveCursorToEnd()
    }

    private func popToRoot(refresh: Bool) {
        if stack.count > 1 { stack.removeLast(stack.count - 1) }
        popState(refresh: refresh)
    }

    private func placeholder(for m: Mode) -> String {
        switch m {
        case .search: return Self.placeholder
        case .actions(let t, let b): return b || t.count > 1 ? "对已选的 \(t.count) 个文件执行…" : "对「\(t.first?.lastPathComponent ?? "")」执行…"
        case .openWith(let u): return "用哪个应用打开「\(u.lastPathComponent)」？"
        case .destinations(let t, let move, _):
            let what = t.count > 1 ? "\(t.count) 个文件" : "「\(t.first?.lastPathComponent ?? "")」"
            return (move ? "把\(what)移动到…" : "把\(what)复制到…")
        case .rename: return "输入新名称"
        case .aiHistory: return "搜索 AI 历史…"
        }
    }

    private func showSub(_ m: Mode, items list: [SearchItem]) {
        push(m)
        subItems = list
        searchField.stringValue = ""
        searchField.placeholderString = placeholder(for: m)
        setItems(list)
        select(row: 0)
    }

    private func filterSubItems() {
        let tokens = ParsedQuery.split(searchField.stringValue)
        if tokens.isEmpty { setItems(subItems); return }
        let filtered: [SearchItem] = subItems.compactMap { it in
            guard let m = NameMatcher.match(it.title, tokens: tokens) else { return nil }
            var x = it
            x.titleRanges = m.ranges
            return x
        }
        setItems(filtered)
    }

    private func showActions(_ targets: [URL], isBuffer: Bool) {
        let list = FileAction.available(for: targets, isBuffer: isBuffer).map { a -> SearchItem in
            var it = SearchItem(kind: .action, url: nil, title: a.title, subtitle: actionSubtitle(a, targets: targets))
            it.action = a
            it.symbol = a.symbol
            it.shortcut = a.shortcut
            return it
        }
        showSub(.actions(targets: targets, isBuffer: isBuffer), items: list)
    }

    private func actionSubtitle(_ a: FileAction, targets: [URL]) -> String {
        let u = targets[0]
        switch a {
        case .openWith:
            if let app = NSWorkspace.shared.urlForApplication(toOpen: u) {
                return "默认：" + FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            }
            return ""
        case .reveal: return FileSearchSettings.abbreviate(u.deletingLastPathComponent().path)
        case .copyPath: return targets.count == 1 ? FileSearchSettings.abbreviate(u.path) : "\(targets.count) 条路径，每行一个"
        case .copyName: return u.lastPathComponent
        case .trash: return "可以按 ⌘Z 撤销"
        case .terminal: return "在终端里进入这个文件夹"
        case .info: return "打开访达的「显示简介」窗口"
        case .moveTo, .copyTo: return "选择目标文件夹"
        case .copyFile: return "可以直接粘贴到访达、微信、邮件等"
        case .clearBuffer: return "取消已选的 \(buffer.count) 个文件"
        default: return ""
        }
    }

    private var actionTargets: (urls: [URL], isBuffer: Bool)? {
        switch mode {
        case .actions(let t, let b): return (t, b)
        case .destinations(let t, _, let b): return (t, b)
        case .openWith(let u): return ([u], false)
        default:
            guard let u = selectedItem?.fileURL else { return nil }
            return ([u], false)
        }
    }

    private func perform(_ a: FileAction) {
        guard let (targets, isBuffer) = actionTargets, !targets.isEmpty else { NSSound.beep(); return }
        switch a {
        case .open:
            targets.forEach(recordUsage)
            FileOps.open(targets)
            onClose?()
        case .openWith:
            let u = targets[0]
            let apps = FileOps.openWithApps(for: u)
            guard !apps.isEmpty else { ScreenshotToast.show("没有可以打开这个文件的应用"); return }
            let list = apps.enumerated().map { i, app -> SearchItem in
                var name = FileManager.default.displayName(atPath: app.path)
                if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
                return SearchItem(kind: .openWithApp, url: app, title: name,
                                  subtitle: (i == 0 ? "默认 · " : "") + FileSearchSettings.abbreviate(app.deletingLastPathComponent().path))
            }
            showSub(.openWith(u), items: list)
        case .reveal:
            targets.forEach(recordUsage)
            FileOps.reveal(targets)
            onClose?()
        case .copyFile:
            FileOps.copyFiles(targets)
            onClose?()
            ScreenshotToast.show(targets.count > 1 ? "已复制 \(targets.count) 个文件" : "已复制文件")
        case .copyPath:
            FileOps.copyText(targets.map(\.path).joined(separator: "\n"))
            onClose?()
            ScreenshotToast.show("已复制路径")
        case .copyName:
            FileOps.copyText(targets.map(\.lastPathComponent).joined(separator: "\n"))
            onClose?()
            ScreenshotToast.show("已复制文件名")
        case .moveTo, .copyTo:
            showDestinations(targets, move: a == .moveTo, isBuffer: isBuffer)
        case .rename:
            startRename(targets[0])
        case .trash:
            trash(targets, isBuffer: isBuffer)
        case .terminal:
            FileOps.openInTerminal(targets[0])
            onClose?()
        case .info:
            FileOps.showInfo(targets)
            onClose?()
        case .quit, .forceQuit:
            let ok = FileOps.quit(targets[0], force: a == .forceQuit)
            onClose?()
            ScreenshotToast.show(ok ? (a == .forceQuit ? "已强制退出" : "已退出") : "应用没有在运行")
        case .clearBuffer:
            buffer = []
            rebuildBufferBar()
            popToRoot(refresh: false)
        }
    }

    private func showDestinations(_ targets: [URL], move: Bool, isBuffer: Bool) {
        var paths = FileSearchSettings.recentTargets.map(FileSearchSettings.expand)
        for d in ["~/Desktop", "~/Downloads", "~/Documents"].map(FileSearchSettings.expand) where !paths.contains(d) {
            paths.append(d)
        }
        var list: [SearchItem] = paths.map { p in
            SearchItem(kind: .destination, url: URL(fileURLWithPath: p), title: FileManager.default.displayName(atPath: p),
                       subtitle: FileSearchSettings.abbreviate(p), isDirectory: true)
        }
        var choose = SearchItem(kind: .chooseFolder, url: nil, title: "选择其他文件夹…", subtitle: "打开系统的选择窗口")
        choose.symbol = "folder.badge.questionmark"
        list.append(choose)
        showSub(.destinations(targets: targets, move: move, isBuffer: isBuffer), items: list)
    }

    private func transfer(to dir: URL) {
        guard case .destinations(let targets, let move, _) = mode else { return }
        onClose?()
        Self.doTransfer(targets, to: dir, move: move)
    }

    private static func doTransfer(_ targets: [URL], to dir: URL, move: Bool) {
        let r = FileOps.transfer(targets, to: dir, move: move)
        FileSearchSettings.addRecentTarget(dir.path)
        if let e = r.errors.first {
            ScreenshotToast.show((r.done.isEmpty ? "" : "部分完成。") + e, duration: 3)
        } else if r.done.isEmpty {
            ScreenshotToast.show("文件已经在「\(dir.lastPathComponent)」里")
        } else {
            let what = r.done.count > 1 ? "\(r.done.count) 个文件" : "「\(r.done[0].lastPathComponent)」"
            ScreenshotToast.show((move ? "已把\(what)移动到「" : "已把\(what)复制到「") + dir.lastPathComponent + "」", duration: 2)
        }
    }

    private func chooseAndTransfer() {
        guard case .destinations(let targets, let move, _) = mode else { return }
        onChooseFolder?(move ? "选择要移动到的文件夹" : "选择要复制到的文件夹") { url in
            guard let url = url else { return }
            Self.doTransfer(targets, to: url, move: move)
        }
    }

    private func startRename(_ url: URL) {
        push(.rename(url))
        var it = SearchItem(kind: .message, url: url, title: "重命名「\(url.lastPathComponent)」",
                            subtitle: "输入新名称后按 ⏎ 确认，Esc 取消")
        it.shortcut = " "
        subItems = []
        searchField.placeholderString = placeholder(for: .rename(url))
        searchField.stringValue = url.lastPathComponent
        setItems([it])
        window?.makeFirstResponder(searchField)
        // 默认选中文件名（不含扩展名），和访达一致
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        searchField.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    private func commitRename() {
        guard case .rename(let url) = mode else { return }
        do {
            let new = try FileOps.rename(url, to: searchField.stringValue)
            if new != url {
                FileSearchUsage.shared.remove(path: url.path)
                ScreenshotToast.show("已重命名为「\(new.lastPathComponent)」")
            }
            popToRoot(refresh: true)
            pendingSelectURL = new
        } catch {
            ScreenshotToast.show(error.localizedDescription, duration: 2.4)
        }
    }

    private func trash(_ targets: [URL], isBuffer: Bool) {
        FileOps.trash(targets) { [weak self] map, err in
            guard let self = self else { return }
            guard !map.isEmpty else {
                ScreenshotToast.show("未能移到废纸篓" + (err.map { "：\($0.localizedDescription)" } ?? ""), duration: 2.6)
                return
            }
            self.lastTrash = (map, Date())
            targets.forEach { FileSearchUsage.shared.remove(path: $0.path) }
            if isBuffer || targets.contains(where: { self.buffer.contains($0) }) {
                self.buffer.removeAll { targets.contains($0) }
                self.rebuildBufferBar()
            }
            let what = map.count > 1 ? "\(map.count) 个文件" : "「\(targets[0].lastPathComponent)」"
            ScreenshotToast.show("已把\(what)移到废纸篓 · ⌘Z 撤销", duration: 2.4)
            self.popToRoot(refresh: true)
        }
    }

    private func undoTrash() {
        guard let t = lastTrash else { return }
        lastTrash = nil
        let n = FileOps.restore(t.map)
        ScreenshotToast.show(n > 0 ? "已撤销，恢复了 \(n) 个文件" : "无法撤销（文件已不在废纸篓里）")
        if isSearchMode { runSearch() }
        pendingSelectURL = t.map.keys.first
    }

    private func recordUsage(_ url: URL) {
        let text = stack.first?.text ?? searchField.stringValue
        if case .browse = ParsedQuery.parse(text) {
            FileSearchUsage.shared.record(path: url.path, query: "")
        } else {
            FileSearchUsage.shared.record(path: url.path, query: text)
        }
    }

    // MARK: 执行

    private func activate(_ item: SearchItem, alternate: Bool) {
        switch item.kind {
        case .app, .file:
            guard let url = item.url else { return }
            var reveal = false
            if case .name(_, _, true) = query { reveal = true }
            if alternate { reveal.toggle() }
            recordUsage(url)
            if reveal { FileOps.reveal([url]) } else { FileOps.open([url]) }
            onClose?()
        case .action:
            if let a = item.action { perform(a) }
        case .openWithApp:
            guard case .openWith(let target) = mode, let app = item.url else { return }
            recordUsage(target)
            FileOps.open(target, with: app)
            onClose?()
        case .destination:
            if let u = item.url { transfer(to: u) }
        case .chooseFolder:
            chooseAndTransfer()
        case .aiRecord:
            if let r = item.record { enterAI(AIConversation(record: r)) }
        case .message:
            if case .rename = mode { commitRename() } else { NSSound.beep() }
        }
    }

    /// →：文件夹进入浏览，文件打开操作菜单
    private func rightArrow(_ item: SearchItem) -> Bool {
        switch item.kind {
        case .app, .file:
            guard let u = item.url else { return false }
            if item.isDirectory && !item.isCurrentFolder {
                enterBrowse(u)
            } else {
                showActions([u], isBuffer: false)
            }
            return true
        case .action:
            if let a = item.action, [.openWith, .moveTo, .copyTo].contains(a) { perform(a); return true }
            return false
        case .aiRecord:
            activate(item, alternate: false)
            return true
        default:
            return false
        }
    }

    private static func displayPath(_ p: String) -> String {
        if p == "/" { return "" }
        return FileSearchSettings.abbreviate(p)
    }

    private func enterBrowse(_ dir: URL) {
        if !isSearchMode { popToRoot(refresh: false) }
        setText(Self.displayPath(dir.path) + "/")
    }

    private func goParent() {
        guard case .browse(let dir, _) = query, dir != "/" else { NSSound.beep(); return }
        let parent = (dir as NSString).deletingLastPathComponent
        pendingSelectURL = URL(fileURLWithPath: dir)
        setText(Self.displayPath(parent.isEmpty ? "/" : parent) + "/")
    }

    private func tabComplete() {
        guard isSearchMode, let item = selectedItem, let u = item.fileURL else { NSSound.beep(); return }
        if isBrowsing {
            if item.isCurrentFolder { return }
            setText(Self.displayPath(u.path) + (item.isDirectory ? "/" : ""))
        } else if item.isDirectory {
            setText(Self.displayPath(u.path) + "/")
        } else {
            pendingSelectURL = u
            setText(Self.displayPath(u.deletingLastPathComponent().path) + "/" + u.lastPathComponent)
        }
    }

    // MARK: AI 历史（⌘H）

    private func toggleAIHistory() {
        if case .aiHistory = mode { popState(); return }
        if !isSearchMode { popToRoot(refresh: false) }
        push(.aiHistory)
        subItems = []
        searchField.stringValue = ""
        searchField.placeholderString = placeholder(for: .aiHistory)
        reloadHistory()
    }

    private func reloadHistory() {
        let tokens = ParsedQuery.split(searchField.stringValue)
        let list = AIHistoryStore.shared.sessions.filter { r in
            guard !tokens.isEmpty else { return true }
            let hay = r.title + "\n" + r.engine.name + "\n" + r.turns.map { $0.query + "\n" + ($0.input ?? "") + "\n" + $0.answer }.joined()
            return tokens.allSatisfy { hay.range(of: $0, options: NameMatcher.opts) != nil }
        }
        setItems(list.map { r in
            var sub = [r.engine.name, ClipboardHistoryView.relativeTime(r.updatedAt)]
            if r.turns.count > 1 { sub.append("\(r.turns.count) 轮") }
            let plain = MarkdownRenderer.plainText(r.lastAnswer).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if !plain.isEmpty { sub.append(String(plain.prefix(80))) }
            var it = SearchItem(kind: .aiRecord, url: nil, title: r.title, subtitle: sub.joined(separator: " · "))
            it.record = r
            it.symbol = "sparkles"
            return it
        })
    }

    @objc private func aiHistoryChanged() {
        guard window?.isVisible == true, !isAIMode, case .aiHistory = mode else { return }
        reloadHistory()
    }

    private var selectedRecord: AISessionRecord? { selectedItem?.record }

    private func handleAIHistoryKey(_ e: NSEvent, mods: NSEvent.ModifierFlags) -> Bool? {
        if let idx = Self.numberKeys[e.keyCode], mods == [.option] {
            if idx < items.count, let r = items[idx].record {
                let s = MarkdownRenderer.plainText(r.lastAnswer)
                if !s.isEmpty { onPasteText?(s) }
            }
            return true
        }
        guard mods == [.command], let r = selectedRecord else { return nil }
        switch e.keyCode {
        case 8:
            if AIOutput.copy(MarkdownRenderer.plainText(r.lastAnswer)) { ScreenshotToast.show("已复制回答") }
            return true
        case 35: onPin?(AIConversation(record: r)); return true
        case 51:
            let row = tableView.selectedRow
            AIHistoryStore.shared.remove(r.id)
            reloadHistory()
            select(row: row)
            return true
        case 1:
            ScreenshotToast.show(ShelfStore.shared.addText(r.lastAnswer) ? "已存入暂存板" : "未能存入暂存板")
            return true
        default: return nil
        }
    }

    // MARK: 键盘

    static let numberKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
                                            83: 0, 84: 1, 85: 2, 86: 3, 87: 4, 88: 5, 89: 6, 91: 7, 92: 8]

    func handleKey(_ e: NSEvent) -> Bool {
        let editor = searchField.currentEditor() as? NSTextView
        // 输入法正在组字时，方向键 / 回车 / Esc 交给输入法
        if editor?.hasMarkedText() == true { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if isAIMode { return handleAIKey(e, mods: mods, editor: editor) }

        let text = searchField.stringValue
        let sel = editor?.selectedRange() ?? NSRange(location: (text as NSString).length, length: 0)
        let atEnd = sel.length == 0 && sel.location >= (text as NSString).length

        if e.keyCode == 53 {   // Esc
            if isSearchMode { onClose?() } else { popState() }
            return true
        }
        if case .rename = mode {
            if e.keyCode == 36 || e.keyCode == 76 { commitRename(); return true }
            if mods == [.command], e.keyCode == 13 { onClose?(); return true }
            return handleEditingKey(e, mods: mods, editor: editor)
        }
        if case .aiHistory = mode, let handled = handleAIHistoryKey(e, mods: mods) { return handled }

        // 输入框为空时按空格：变成 '，开始搜索文件夹
        if e.keyCode == 49, mods.isEmpty, isSearchMode, text.isEmpty {
            setText("'")
            return true
        }

        // 翻页键（可在偏好设置里自定义，默认 PageUp / PageDown）
        if let dir = pageDirection(e, mods: mods) {
            moveSelection(dir * Self.maxRows)
            return true
        }

        if let idx = Self.numberKeys[e.keyCode] {
            if mods == [.option] {
                if idx < items.count { select(row: idx); activate(items[idx], alternate: false) }
                return true
            }
            if mods == [.command] { webSearch(index: idx); return true }
        }

        switch e.keyCode {
        case 126:   // ↑
            if mods == [.option] { addToBuffer(advance: false); return true }
            if mods.contains(.command) {
                if isBrowsing { goParent() } else { userMovedSelection = true; select(row: 0) }
                return true
            }
            moveSelection(-1); return true
        case 125:   // ↓
            if mods == [.option] { addToBuffer(advance: true); return true }
            if mods.contains(.command) {
                if isBrowsing, let it = selectedItem, it.isDirectory, !it.isCurrentFolder, let u = it.url { enterBrowse(u) }
                else { userMovedSelection = true; select(row: items.count - 1) }
                return true
            }
            moveSelection(1); return true
        case 36, 76:   // ⏎
            guard let item = selectedItem else { NSSound.beep(); return true }
            activate(item, alternate: mods.contains(.command))
            return true
        case 124:   // →
            if mods == [.option] {
                if buffer.isEmpty { NSSound.beep() } else { showActions(buffer, isBuffer: true) }
                return true
            }
            guard mods.isEmpty, atEnd, let item = selectedItem else { return false }
            return rightArrow(item)
        case 123:   // ←
            if mods == [.option] { removeLastFromBuffer(); return true }
            guard mods.isEmpty else { return false }
            if !isSearchMode, text.isEmpty { popState(); return true }
            if isBrowsing, atEnd, text.hasSuffix("/") { goParent(); return true }
            return false
        case 48:   // Tab
            if isSearchMode { tabComplete() }
            return true
        default: break
        }

        guard mods.contains(.command) else { return false }
        switch (e.keyCode, mods) {
        case (8, [.command]):   // ⌘C：复制路径
            if let ed = editor, ed.selectedRange().length > 0 { ed.copy(nil); return true }
            guard let u = selectedItem?.fileURL else { NSSound.beep(); return true }
            FileOps.copyText(u.path)
            onClose?()
            ScreenshotToast.show("已复制路径")
            return true
        case (8, [.command, .option]):   // ⌥⌘C：复制文件
            guard let u = selectedItem?.fileURL else { NSSound.beep(); return true }
            recordUsage(u)
            FileOps.copyFiles([u])
            onClose?()
            ScreenshotToast.show("已复制文件")
            return true
        case (40, [.command]):   // ⌘K
            if let u = selectedItem?.fileURL, isSearchMode { showActions([u], isBuffer: false) } else { NSSound.beep() }
            return true
        case (4, [.command]):   // ⌘H
            toggleAIHistory(); return true
        case (43, [.command]):   // ⌘,
            onOpenPrefs?(); return true
        case (6, [.command]):   // ⌘Z
            if let t = lastTrash, Date().timeIntervalSince(t.at) < 120 { undoTrash() } else { editor?.undoManager?.undo() }
            return true
        default:
            return handleEditingKey(e, mods: mods, editor: editor)
        }
    }

    /// ⌘A / ⌘V / ⌘X / ⌘W：面板不激活应用，菜单栏快捷键不会生效，这里手动处理
    private func handleEditingKey(_ e: NSEvent, mods: NSEvent.ModifierFlags, editor: NSTextView?) -> Bool {
        guard mods == [.command] else { return false }
        switch e.keyCode {
        case 13: onClose?(); return true
        case 0: editor?.selectAll(nil); return true
        case 9: editor?.paste(nil); return true
        case 7: editor?.cut(nil); return true
        case 8: editor?.copy(nil); return true
        case 6: editor?.undoManager?.undo(); return true
        default: return false
        }
    }

    // MARK: ⌘1–9 模板

    private func oneLine(_ s: String) -> String {
        String(s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(1000))
    }

    private func webSearch(index: Int) {
        let engines = WebSearch.shortcutEngines
        guard index < engines.count else { NSSound.beep(); return }
        let engine = engines[index]
        let typed: String
        switch mode {
        case .search, .aiHistory: typed = ParsedQuery.templateText(searchField.stringValue)
        default: NSSound.beep(); return
        }

        if isAIMode, typed.isEmpty, let first = conversation?.turns.first {
            let text = first.input ?? first.query
            if engine.isAI {
                if first.hasImage, let id = first.imageClipID { startAIWithImage(engine, clipID: id) }
                else if !text.isEmpty { startAI(engine, text: text) }
                else { NSSound.beep() }
            } else if !text.isEmpty {
                onWebSearch?(engine, oneLine(text))
            } else { NSSound.beep() }
            return
        }
        if case .aiHistory = mode, typed.isEmpty, let r = selectedRecord {
            let text = r.turns.first.map { $0.input ?? $0.query } ?? r.title
            if engine.isAI { startAI(engine, text: text) } else { onWebSearch?(engine, oneLine(text)) }
            return
        }
        if !typed.isEmpty {
            if engine.isAI { startAI(engine, text: typed) } else { onWebSearch?(engine, typed) }
            return
        }
        // 输入框为空：处理剪贴板里的内容
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let f = urls.first {
            if engine.kind == .aiPrompt, let content = Self.smallTextContent(f) { startAI(engine, text: content) }
            else {
                let name = f.deletingPathExtension().lastPathComponent
                if engine.isAI { startAI(engine, text: name) } else { onWebSearch?(engine, name) }
            }
        } else if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if engine.kind == .aiPrompt { startAI(engine, text: String(s.prefix(60_000))) }
            else if engine.isAI { startAI(engine, text: oneLine(s)) }
            else { onWebSearch?(engine, oneLine(s)) }
        } else if engine.isAI, let img = NSImage(pasteboard: pb), let data = AIClient.jpegData(img) {
            guard ensureAIConfigured() else { return }
            let c = AIConversation(engine: engine)
            enterAI(c)
            c.start(query: "", input: nil, image: data, imageClipID: nil)
        } else {
            ScreenshotToast.show(engine.isAI ? "请先输入内容（输入框为空时使用剪贴板里的文字或图片）" : "请先输入要搜索的内容", duration: 2.2)
        }
    }

    private static func smallTextContent(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
              v.contentType?.conforms(to: .text) == true, (v.fileSize ?? .max) < 400_000,
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return "文件《\(url.lastPathComponent)》的内容：\n\n" + s
    }

    // MARK: AI 回答

    private func startAI(_ engine: WebSearchEngine, text: String) {
        guard ensureAIConfigured() else { return }
        let c = AIConversation(engine: engine)
        enterAI(c)
        if engine.kind == .aiSearch {
            c.start(query: oneLine(text), input: nil, image: nil, imageClipID: nil)
        } else {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            c.start(query: String(firstLine.prefix(200)), input: text, image: nil, imageClipID: nil)
        }
    }

    private func startAIWithImage(_ engine: WebSearchEngine, clipID: UUID) {
        guard ensureAIConfigured() else { return }
        guard let img = NSImage(contentsOf: ClipboardStore.shared.imageURL(clipID)), let data = AIClient.jpegData(img) else {
            ScreenshotToast.show("图片已失效")
            return
        }
        let c = AIConversation(engine: engine)
        enterAI(c)
        c.start(query: "", input: nil, image: data, imageClipID: clipID)
    }

    private func ensureAIConfigured() -> Bool {
        guard AISettings.isConfigured else {
            ScreenshotToast.show("请先在「偏好设置 → AI」中填写接口地址、API Key 和模型", duration: 2.6)
            onOpenAISettings?()
            return false
        }
        return true
    }

    private func makeAIView() -> AIResultView {
        let v = AIResultView(frame: NSRect(x: 0, y: Self.footerH + 1, width: bounds.width, height: 300))
        v.isHidden = true
        v.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        v.onCopyText = { s in AIOutput.copy(s); ScreenshotToast.show("已复制") }
        v.onAsked = { [weak self] in self?.searchField.stringValue = "" }
        v.onAction = { [weak self] a in self?.performAIAction(a) }
        bg.addSubview(v)
        aiView = v
        return v
    }

    private func performAIAction(_ a: String) {
        switch a {
        case "copy": if AIOutput.copy(AIOutput.answerPlain(conversation)) { ScreenshotToast.show("已复制回答") }
        case "copymd": if AIOutput.copy(AIOutput.answerMarkdown(conversation)) { ScreenshotToast.show("已复制 Markdown") }
        case "retry": conversation?.regenerate()
        case "shelf": AIOutput.saveToShelf(conversation)
        case "settings": onOpenAISettings?()
        default: break
        }
    }

    private func enterAI(_ c: AIConversation) {
        if let old = conversation, old !== c { old.stop() }
        spotlight.stop()
        debounce?.cancel()
        searching = false
        conversation = c
        let v = aiView ?? makeAIView()
        v.attach(c)
        setAIMode(true)
    }

    private func exitAI(reload: Bool) {
        conversation?.stop()
        aiView?.attach(nil)
        conversation = nil
        setAIMode(false)
        if reload { textChanged(immediate: true) }
    }

    private var savedText = ""

    private func setAIMode(_ on: Bool) {
        if on && !isAIMode { savedText = searchField.stringValue }
        isAIMode = on
        aiView?.isHidden = !on
        searchField.stringValue = on ? "" : savedText
        searchField.placeholderString = on ? Self.aiPlaceholder : placeholder(for: mode)
        headerIcon.image = NSImage(systemSymbolName: on ? "sparkles" : "magnifyingglass", accessibilityDescription: nil)
        headerIcon.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        refreshChrome()
        window?.makeFirstResponder(searchField)
        moveCursorToEnd()
    }

    private func handleAIKey(_ e: NSEvent, mods: NSEvent.ModifierFlags, editor: NSTextView?) -> Bool {
        let typed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dir = pageDirection(e, mods: mods) { aiView?.page(dir); return true }
        switch e.keyCode {
        case 53:
            if conversation?.isRunning == true { conversation?.stop() } else { exitAI(reload: true) }
            return true
        case 36, 76:
            if !typed.isEmpty {
                conversation?.ask(typed)
                searchField.stringValue = ""
            } else {
                let s = mods.contains(.shift) ? AIOutput.answerMarkdown(conversation) : AIOutput.answerPlain(conversation)
                if s.isEmpty { NSSound.beep() } else { onPasteText?(s) }
            }
            return true
        case 126:
            if mods.contains(.command) { aiView?.scrollToEdge(top: true) } else { aiView?.scroll(by: -80) }
            return true
        case 125:
            if mods.contains(.command) { aiView?.scrollToEdge(top: false) } else { aiView?.scroll(by: 80) }
            return true
        case 48: return true
        default: break
        }
        if let idx = Self.numberKeys[e.keyCode] {
            if mods == [.command] { webSearch(index: idx); return true }
            if mods == [.option] { return true }
        }
        guard mods.contains(.command) else { return false }
        switch e.keyCode {
        case 8:   // ⌘C：输入框选中文字 → 回答中选中的文字 → 整个回答；⇧⌘C 复制 Markdown
            if let ed = editor, ed.selectedRange().length > 0 { ed.copy(nil); return true }
            let md = mods.contains(.shift)
            let c = conversation
            aiView?.selectedText { sel in
                if !sel.isEmpty && !md { AIOutput.copy(sel); ScreenshotToast.show("已复制选中内容"); return }
                let s = md ? AIOutput.answerMarkdown(c) : AIOutput.answerPlain(c)
                if AIOutput.copy(s) { ScreenshotToast.show(md ? "已复制 Markdown" : "已复制回答") } else { NSSound.beep() }
            }
            return true
        case 35:   // ⌘P：钉住为独立窗口
            guard let c = conversation else { return true }
            aiView?.attach(nil)
            conversation = nil
            onPin?(c)
            return true
        case 15: conversation?.regenerate(); return true   // ⌘R
        case 1: AIOutput.saveToShelf(conversation); return true   // ⌘S
        case 13: onClose?(); return true
        case 0: editor?.selectAll(nil); return true
        case 9: editor?.paste(nil); return true
        case 7: editor?.cut(nil); return true
        case 6: editor?.undoManager?.undo(); return true
        default: return true
        }
    }
}
