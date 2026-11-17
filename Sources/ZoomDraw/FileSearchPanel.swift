import AppKit

/// 文件搜索浮窗：不激活本应用（前台应用保持不变，AI 回答才能粘贴回原处），键盘输入直接进入搜索框
final class SearchPanelWindow: NSPanel {
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

/// 文件搜索：显示 / 隐藏、位置、粘贴回原应用
final class FileSearchController: NSObject, NSWindowDelegate {
    static let shared = FileSearchController()

    private var panel: SearchPanelWindow?
    private(set) var view: FileSearchView?
    /// 打开搜索框前的前台应用（AI 回答粘贴的目标）
    private var targetApp: NSRunningApplication?
    private var hiddenAt: Date?
    private var anchorTop: CGFloat = 0
    /// 弹出「选择文件夹」等系统窗口期间不要因为失去焦点而收起
    private var suppressAutoHide = false

    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    /// 开启右侧预览时窗口加宽
    static var width: CGFloat { FileSearchSettings.preview ? 940 : 720 }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        let resume = view?.canResumeAI == true && hiddenAt.map { Date().timeIntervalSince($0) < 120 } == true
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp = front
        } else if !resume {
            targetApp = nil
        }
        AppCatalog.shared.ensureLoaded()

        let p = panel ?? makePanel()
        if resume { view?.prepareForResume() } else { view?.prepareForShow() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            anchorTop = (vf.maxY - vf.height * 0.18).rounded()
            let h = view?.preferredHeight ?? FileSearchView.headerH
            p.setFrame(frame(height: h, in: vf, x: (vf.midX - Self.width / 2).rounded()), display: false)
        }
        onVisibilityChanged?(true)
        p.makeKeyAndOrderFront(nil)
        if let v = view { p.makeFirstResponder(v.searchField); v.moveCursorToEnd() }
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        hiddenAt = Date()
        view?.didHide()
        onVisibilityChanged?(false)
    }

    private func frame(height h: CGFloat, in vf: NSRect, x: CGFloat) -> NSRect {
        var top = anchorTop
        if top - h < vf.minY + 10 { top = min(vf.maxY - 10, vf.minY + 10 + h) }
        return NSRect(x: x, y: top - h, width: Self.width, height: h)
    }

    private func applyHeight(_ h: CGFloat) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(p.frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let f = frame(height: min(h, vf.height - 20), in: vf, x: p.frame.minX)
        if f != p.frame { p.setFrame(f, display: true) }
    }

    private func makePanel() -> SearchPanelWindow {
        let size = NSSize(width: Self.width, height: FileSearchView.headerH)
        let p = SearchPanelWindow(size: size)
        let v = FileSearchView(frame: NSRect(origin: .zero, size: size))
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        p.delegate = self
        p.keyHandler = { [weak v] e in v?.handleKey(e) ?? false }

        v.onClose = { [weak self] in self?.hide() }
        v.onHeightChanged = { [weak self] h in self?.applyHeight(h) }
        v.onWebSearch = { [weak self] engine, query in
            self?.hide()
            if !WebSearch.open(engine, query: query) { ScreenshotToast.show("「\(engine.name)」的网址模板无效") }
        }
        v.onPasteText = { [weak self] text in
            guard AIOutput.copy(text) else { return }
            self?.hide()
            self?.hiddenAt = nil
            ClipboardController.pasteFromPasteboard(into: self?.targetApp)
        }
        v.onPin = { [weak self] c in
            let frame = self?.panel?.frame
            self?.hide()
            AIPinnedWindowController.pin(c, near: frame)
        }
        v.onOpenAISettings = { [weak self] in
            self?.hide()
            PreferencesWindowController.shared.show(tab: "ai")
        }
        v.onOpenPrefs = { [weak self] in
            self?.hide()
            PreferencesWindowController.shared.show(tab: "filesearch")
        }
        v.onOpenURL = { [weak self] url in
            self?.hide()
            AIOutput.open(url)
        }
        v.onChooseFolder = { [weak self] title, completion in self?.chooseFolder(title: title, completion: completion) }

        panel = p
        view = v
        return p
    }

    /// 选择文件夹：先收起搜索框，再弹出系统的选择窗口
    private func chooseFolder(title: String, completion: @escaping (URL?) -> Void) {
        suppressAutoHide = true
        hide()
        suppressAutoHide = false
        let op = NSOpenPanel()
        op.canChooseFiles = false
        op.canChooseDirectories = true
        op.canCreateDirectories = true
        op.allowsMultipleSelection = false
        op.prompt = "选择"
        op.message = title
        NSApp.activate(ignoringOtherApps: true)
        completion(op.runModal() == .OK ? op.url : nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let p = panel, (notification.object as? NSWindow) === p, !suppressAutoHide else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.panel, p.isVisible, !p.isKeyWindow else { return }
            self.hide()
        }
    }
}

// MARK: - 列表条目

struct SearchItem {
    enum Kind { case app, file, action, openWithApp, destination, chooseFolder, aiRecord, message }

    var kind: Kind
    var url: URL?
    var title: String
    var subtitle: String
    var titleRanges: [NSRange] = []
    var isDirectory = false
    var isCurrentFolder = false
    /// 正文搜索的结果：多一行命中片段
    var contentHit = false
    var action: FileAction?
    var record: AISessionRecord?
    var symbol: String?
    var shortcut: String = ""

    var fileURL: URL? { kind == .app || kind == .file ? url : nil }
}

enum ParsedQuery {
    case empty
    case name(tokens: [String], apps: Bool, reveal: Bool)
    case content(tokens: [String])
    case tags(tokens: [String])
    /// 以 ' 开头（输入框为空时按空格会自动变成 '）：只搜文件夹
    case folders(tokens: [String])
    case browse(dir: String, filter: String)
    case hint(String)

    var tokens: [String] {
        switch self {
        case .name(let t, _, _), .content(let t), .tags(let t), .folders(let t): return t
        case .browse(_, let f): return Self.split(f)
        default: return []
        }
    }

    static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// 文件夹搜索的前缀：半角 ' 以及中文输入法打出的 ‘ ’
    static let folderPrefixes: Set<Character> = ["'", "\u{2018}", "\u{2019}"]

    static func hasFolderPrefix(_ text: String) -> Bool {
        text.first.map { folderPrefixes.contains($0) } ?? false
    }

    /// ' 文件夹 · in 正文 · tags 标签 · open / find（可在设置中开启）· / 或 ~ 浏览 · 其余按名称搜应用和文件
    static func parse(_ text: String) -> ParsedQuery {
        let lead = String(text.drop(while: { $0 == " " }))
        if lead.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if hasFolderPrefix(lead) {
            let r = String(lead.dropFirst()).trimmingCharacters(in: .whitespaces)
            return r.isEmpty ? .hint("输入要搜索的文件夹名称") : .folders(tokens: split(r))
        }
        if lead.hasPrefix("/") || lead.hasPrefix("~") {
            let raw = lead == "~" ? "~/" : lead
            let expanded = (raw as NSString).expandingTildeInPath
            if raw.hasSuffix("/") {
                var dir = expanded
                while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
                return .browse(dir: dir.isEmpty ? "/" : dir, filter: "")
            }
            let ns = expanded as NSString
            let dir = ns.deletingLastPathComponent
            return .browse(dir: dir.isEmpty ? "/" : dir, filter: ns.lastPathComponent)
        }
        let lower = lead.lowercased()
        // 只有「关键字 + 空格」才算关键字（单独输入 in 照常按名称搜索）
        func rest(_ kw: String) -> String? {
            guard lower.hasPrefix(kw + " ") else { return nil }
            return String(lead.dropFirst(kw.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        if let r = rest("in") {
            return r.isEmpty ? .hint("输入要在正文里搜索的内容") : .content(tokens: split(r))
        }
        if FileSearchSettings.tagsKeyword, let r = rest("tags") {
            return r.isEmpty ? .hint("输入访达标签名称") : .tags(tokens: split(r))
        }
        if FileSearchSettings.openFindKeywords {
            if let r = rest("open") {
                return r.isEmpty ? .hint("输入要打开的文件名") : .name(tokens: split(r), apps: false, reveal: false)
            }
            if let r = rest("find") {
                return r.isEmpty ? .hint("输入要在访达中显示的文件名") : .name(tokens: split(r), apps: false, reveal: true)
            }
        }
        return .name(tokens: split(lead), apps: FileSearchSettings.searchApps, reveal: false)
    }

    /// ⌘1–9 模板使用的文字：去掉 in / tags 等关键字
    static func templateText(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasFolderPrefix(t) { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let lower = t.lowercased()
        for kw in ["in ", "tags ", "open ", "find "] where lower.hasPrefix(kw) {
            return String(t.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

// MARK: - 行视图

final class FileResultTableView: NSTableView {
    var onRightClick: ((Int) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onRightClick?(row) } else { super.rightMouseDown(with: event) }
    }
}

final class FileResultCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private var hasSnippet = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        for l in [titleLabel, subtitleLabel, snippetLabel] {
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            l.cell?.truncatesLastVisibleLine = true
            addSubview(l)
        }
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.alignment = .right
        addSubview(keyLabel)
        checkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已选")
        checkView.contentTintColor = .controlAccentColor
        addSubview(checkView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let iconS: CGFloat = 32
        iconView.frame = NSRect(x: 18, y: ((H - iconS) / 2).rounded(), width: iconS, height: iconS)
        checkView.frame = NSRect(x: 40, y: ((H - iconS) / 2).rounded() - 2, width: 14, height: 14)
        let x: CGFloat = 62, w = W - x - 64
        keyLabel.frame = NSRect(x: W - 56, y: (H / 2 - 8).rounded(), width: 40, height: 16)
        if hasSnippet {
            titleLabel.frame = NSRect(x: x, y: H - 25, width: w, height: 18)
            snippetLabel.frame = NSRect(x: x, y: H - 44, width: w, height: 16)
            subtitleLabel.frame = NSRect(x: x, y: 7, width: w, height: 14)
        } else {
            titleLabel.frame = NSRect(x: x, y: (H / 2).rounded(), width: w, height: 18)
            subtitleLabel.frame = NSRect(x: x, y: (H / 2 - 17).rounded(), width: w, height: 14)
        }
    }

    func configure(_ item: SearchItem, index: Int, icon: NSImage?, snippet: FileSnippet.Result??, inBuffer: Bool) {
        iconView.image = icon
        iconView.contentTintColor = item.symbol != nil ? .secondaryLabelColor : nil
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
        ])
        let len = (item.title as NSString).length
        for r in item.titleRanges where r.location + r.length <= len {
            title.addAttributes([.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                 .foregroundColor: NSColor.controlAccentColor], range: r)
        }
        titleLabel.attributedStringValue = title
        subtitleLabel.stringValue = item.subtitle
        toolTip = item.url?.path

        hasSnippet = item.contentHit
        snippetLabel.isHidden = !item.contentHit
        if item.contentHit {
            switch snippet {
            case .none:
                snippetLabel.attributedStringValue = Self.dim("正在读取…")
            case .some(.none):
                snippetLabel.attributedStringValue = Self.dim("正文命中（此格式无法显示片段）")
            case .some(.some(let s)):
                let a = NSMutableAttributedString(string: s.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let n = (s.text as NSString).length
                for r in s.ranges where r.location + r.length <= n {
                    a.addAttributes([.foregroundColor: NSColor.labelColor,
                                     .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                     .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)], range: r)
                }
                snippetLabel.attributedStringValue = a
            }
        }
        keyLabel.stringValue = item.shortcut.isEmpty ? (index < 9 && item.kind != .message ? "⌥\(index + 1)" : "") : item.shortcut
        checkView.isHidden = !inBuffer
        needsLayout = true
    }

    private static func dim(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])
    }
}
