import AppKit
import UniformTypeIdentifiers

/// 一个搜索模板（⌘1–9）：
/// - 网页：URL 中的 {query} 会被替换为网址编码后的关键字
/// - AI 搜索：先联网搜索，再让 AI 依据搜索结果回答（prompt 为可选的额外要求）
/// - AI 指令：把 prompt 中的 {query} 替换为输入内容后发给 AI（翻译、总结等）
struct WebSearchEngine: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case web, aiSearch, aiPrompt
        var title: String {
            switch self {
            case .web: return "网页"
            case .aiSearch: return "AI 搜索"
            case .aiPrompt: return "AI 指令"
            }
        }
    }

    var id = UUID()
    var name: String
    var url: String
    var enabled: Bool
    var kind: Kind = .web
    var prompt: String = ""

    static let placeholder = "{query}"

    init(name: String, url: String, enabled: Bool) {
        self.name = name; self.url = url; self.enabled = enabled
    }
    init(name: String, kind: Kind, prompt: String, enabled: Bool) {
        self.name = name; self.url = ""; self.enabled = enabled; self.kind = kind; self.prompt = prompt
    }

    /// v2.8 的数据没有 kind / prompt 字段，按网页模板读取
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .web
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }

    var isAI: Bool { kind != .web }
    var isValid: Bool { validationError == nil }

    /// 模板有问题时返回原因
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名称不能为空" }
        switch kind {
        case .aiSearch:
            return nil
        case .aiPrompt:
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "提示词不能为空" : nil
        case .web:
            let t = url.trimmingCharacters(in: .whitespaces)
            if !t.contains(Self.placeholder) { return "网址中需要包含 \(Self.placeholder)" }
            guard let r = t.range(of: ":"), t.distance(from: t.startIndex, to: r.lowerBound) > 0 else {
                return "网址需以 https:// 等协议开头"
            }
            if WebSearch.buildURL(self, query: "test") == nil { return "网址格式不正确" }
            return nil
        }
    }

    /// 表格里显示的内容：网址或提示词（单行）
    var detail: String {
        switch kind {
        case .web: return url
        case .aiSearch, .aiPrompt:
            let p = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            if kind == .aiSearch && p.isEmpty { return "联网搜索后由 AI 总结回答，并标注来源" }
            return p
        }
    }
}

extension Notification.Name {
    static let webSearchChanged = Notification.Name("ZoomDraw.webSearchChanged")
}

enum WebSearch {
    private static let d = UserDefaults.standard
    private static let enginesKey = "websearch.engines"
    private static let browserKey = "websearch.browser"

    /// 快捷键 ⌘1–⌘9，最多 9 个
    static let maxShortcuts = 9

    private static let schemaKey = "websearch.schema"

    // MARK: 模板
    static var engines: [WebSearchEngine] {
        get {
            if let data = d.data(forKey: enginesKey),
               let list = try? JSONDecoder().decode([WebSearchEngine].self, from: data) {
                if d.integer(forKey: schemaKey) < 3 {
                    let migrated = migrateFromV2(list)
                    if let data = try? JSONEncoder().encode(migrated) { d.set(data, forKey: enginesKey) }
                    d.set(3, forKey: schemaKey)
                    return migrated
                }
                return list
            }
            return presets
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: enginesKey) }
            d.set(3, forKey: schemaKey)
            NotificationCenter.default.post(name: .webSearchChanged, object: nil)
        }
    }

    /// 已启用且有效的模板，按顺序对应 ⌘1–⌘9
    static var shortcutEngines: [WebSearchEngine] {
        Array(engines.filter { $0.enabled && $0.isValid }.prefix(maxShortcuts))
    }

    static func resetToPresets() { engines = presets }

    /// v2.8 → v3.0：没改过预置列表的直接换成新预置；改过的保留原有顺序和勾选，
    /// 在最前面加「AI 搜索」（取代百度），后面补上 AI 指令（快捷键还有空位时才勾选）
    static func migrateFromV2(_ old: [WebSearchEngine]) -> [WebSearchEngine] {
        let sig = old.map { "\($0.name)|\($0.url)|\($0.enabled)" }
        if sig == legacyPresetSignature { return presets }

        let ai = presets.filter(\.isAI)
        var out: [WebSearchEngine] = [ai[0]]
        for var e in old {
            if e.name == "百度", e.url.contains("baidu.com/s?") { e.enabled = false }
            out.append(e)
        }
        var used = out.filter { $0.enabled && $0.isValid }.count
        for var e in ai.dropFirst() {
            if e.enabled {
                e.enabled = used < maxShortcuts
                if e.enabled { used += 1 }
            }
            out.append(e)
        }
        return out
    }

    /// v2.8 的预置列表（用于判断用户是否改过）
    private static let legacyPresetSignature: [String] = [
        "百度|https://www.baidu.com/s?ie=UTF-8&wd={query}|true",
        "百度地图|http://map.baidu.com/?newmap=1&ie=utf-8&s=s%26wd%3D{query}|true",
        "Google|https://www.google.com/search?q={query}|true",
        "必应|https://cn.bing.com/search?q={query}|true",
        "知乎|https://www.zhihu.com/search?type=content&q={query}|true",
        "哔哩哔哩|https://search.bilibili.com/all?keyword={query}|true",
        "小红书|https://www.xiaohongshu.com/search_result?keyword={query}|true",
        "淘宝|https://s.taobao.com/search?q={query}|true",
        "有道词典|https://dict.youdao.com/result?word={query}&lang=en|true",
        "GitHub|https://github.com/search?q={query}&type=repositories|false",
        "京东|https://search.jd.com/Search?keyword={query}&enc=utf-8|false",
        "微信文章|https://weixin.sogou.com/weixin?type=2&query={query}|false",
        "豆瓣|https://www.douban.com/search?q={query}|false",
        "维基百科|https://zh.wikipedia.org/w/index.php?search={query}|false",
        "高德地图|https://www.amap.com/search?query={query}|false",
        "YouTube|https://www.youtube.com/results?search_query={query}|false",
        "百度翻译|https://fanyi.baidu.com/mtpe-individual/multimodal?query={query}&lang=auto2zh|false",
        "系统词典|dict://{query}|false",
        "快捷指令（示例）|shortcuts://run-shortcut?name=在此填写快捷指令名称&input=text&text={query}|false",
    ]

    /// 预置模板：AI 搜索 + 常用 AI 指令 + 网页搜索；勾选的按顺序对应 ⌘1–⌘9
    static let presets: [WebSearchEngine] = [
        .init(name: "AI 搜索", kind: .aiSearch, prompt: "", enabled: true),
        .init(name: "百度地图", url: "http://map.baidu.com/?newmap=1&ie=utf-8&s=s%26wd%3D{query}", enabled: true),
    ] + AIPresets.enabled + AIPresets.disabled + [
        .init(name: "百度", url: "https://www.baidu.com/s?ie=UTF-8&wd={query}", enabled: false),
        .init(name: "Google", url: "https://www.google.com/search?q={query}", enabled: false),
        .init(name: "必应", url: "https://cn.bing.com/search?q={query}", enabled: false),
        .init(name: "知乎", url: "https://www.zhihu.com/search?type=content&q={query}", enabled: false),
        .init(name: "哔哩哔哩", url: "https://search.bilibili.com/all?keyword={query}", enabled: false),
        .init(name: "小红书", url: "https://www.xiaohongshu.com/search_result?keyword={query}", enabled: false),
        .init(name: "淘宝", url: "https://s.taobao.com/search?q={query}", enabled: false),
        .init(name: "有道词典", url: "https://dict.youdao.com/result?word={query}&lang=en", enabled: false),
        .init(name: "GitHub", url: "https://github.com/search?q={query}&type=repositories", enabled: false),
        .init(name: "京东", url: "https://search.jd.com/Search?keyword={query}&enc=utf-8", enabled: false),
        .init(name: "微信文章", url: "https://weixin.sogou.com/weixin?type=2&query={query}", enabled: false),
        .init(name: "豆瓣", url: "https://www.douban.com/search?q={query}", enabled: false),
        .init(name: "维基百科", url: "https://zh.wikipedia.org/w/index.php?search={query}", enabled: false),
        .init(name: "高德地图", url: "https://www.amap.com/search?query={query}", enabled: false),
        .init(name: "YouTube", url: "https://www.youtube.com/results?search_query={query}", enabled: false),
        .init(name: "百度翻译", url: "https://fanyi.baidu.com/mtpe-individual/multimodal?query={query}&lang=auto2zh", enabled: false),
        .init(name: "系统词典", url: "dict://{query}", enabled: false),
        .init(name: "快捷指令（示例）",
              url: "shortcuts://run-shortcut?name=在此填写快捷指令名称&input=text&text={query}", enabled: false),
    ]

    // MARK: 浏览器
    /// 打开网页用的浏览器；nil 表示系统默认
    static var browserBundleID: String? {
        get { d.string(forKey: browserKey) }
        set { d.set(newValue, forKey: browserKey) }
    }

    /// 能打开 https 链接的应用
    static func installedBrowsers() -> [URL] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).filter {
            guard let bid = Bundle(url: $0)?.bundleIdentifier else { return false }
            return seen.insert(bid).inserted
        }
    }

    // MARK: 生成与打开
    /// 关键字按 UTF-8 网址编码（只保留 A–Z a–z 0–9 - . _ ~），中文、空格、&、# 等都会编码
    private static let queryAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 模板本身里的非法字符（例如快捷指令名称里的中文）也编码；已有的 %XX 原样保留
    private static let templateAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: UnicodeScalar(0x21)!...UnicodeScalar(0x7E)!)
        s.remove(charactersIn: "\"<>\\^`{|}")
        return s
    }()

    static func buildURL(_ e: WebSearchEngine, query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        let parts = e.url.trimmingCharacters(in: .whitespaces).components(separatedBy: WebSearchEngine.placeholder)
        let encoded = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: templateAllowed) }
        guard encoded.count == parts.count else { return nil }
        let str = encoded.joined(separator: q)
        guard let url = URL(string: str), url.scheme?.isEmpty == false else { return nil }
        return url
    }

    /// 打开搜索；返回是否成功
    @discardableResult
    static func open(_ e: WebSearchEngine, query: String) -> Bool {
        guard let url = buildURL(e, query: query) else { return false }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https", let bid = browserBundleID,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    /// 把剪贴板条目转成搜索关键字：文本 / 链接 / 颜色取文字（多行合并为一行），文件取文件名；图片返回 nil
    static func query(from item: ClipItem) -> String? {
        let raw: String
        switch item.kind {
        case .text, .link, .color:
            raw = ClipboardStore.shared.fullText(of: item)
        case .file:
            guard let first = item.fileURLs.first else { return nil }
            raw = first.deletingPathExtension().lastPathComponent
        case .image:
            return nil
        }
        let line = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let s = String(line.prefix(1000))
        return s.isEmpty ? nil : s
    }

    /// AI 指令的输入：保留换行的全文；文本类小文件读取内容，其他文件用文件名；图片返回 nil（另行识图）
    static func aiInput(from item: ClipItem) -> String? {
        let maxLen = 60_000
        var raw: String
        switch item.kind {
        case .text, .link, .color:
            raw = ClipboardStore.shared.fullText(of: item)
        case .file:
            guard let first = item.existingFileURLs.first ?? item.fileURLs.first else { return nil }
            raw = first.lastPathComponent
            if let type = try? first.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
               type.contentType?.conforms(to: .text) == true, (type.fileSize ?? .max) < 400_000,
               let s = try? String(contentsOf: first, encoding: .utf8) {
                raw = "文件《\(first.lastPathComponent)》的内容：\n\n" + s
            }
        case .image:
            return nil
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count > maxLen { raw = String(raw.prefix(maxLen)) + "\n…（内容过长，已截断）" }
        return raw.isEmpty ? nil : raw
    }
}

/// 预置的 AI 指令（{query} 为输入内容）
enum AIPresets {
    static let enabled: [WebSearchEngine] = [
        .init(name: "翻译", kind: .aiPrompt, prompt: """
            把下面的内容翻译成地道、通顺的目标语言：中文译成英文，其他语言译成简体中文。保留原有格式（换行、列表、代码、专有名词），只输出译文，不要任何解释。

            {query}
            """, enabled: true),
        .init(name: "解释", kind: .aiPrompt, prompt: """
            用通俗易懂的简体中文解释下面的内容：先用一两句话说清它是什么 / 是什么意思，再补充关键细节、背景或例子。如果是缩写、术语、梗或俚语，给出全称和出处。

            {query}
            """, enabled: true),
        .init(name: "总结", kind: .aiPrompt, prompt: """
            总结下面的内容：先用一句话概括核心，再用 3–7 个要点列出关键信息（数字、结论、时间、人物等不要遗漏）；如果有待办或需要注意的地方，最后单独列出。

            {query}
            """, enabled: true),
        .init(name: "润色", kind: .aiPrompt, prompt: """
            润色下面的文字，使其更通顺、准确、得体。保持原意、原语言和大致长度，不要添加新信息。先输出润色后的全文，再用不超过 3 条简短说明主要修改。

            {query}
            """, enabled: true),
        .init(name: "识别图片", kind: .aiPrompt, prompt: """
            识别图片中的内容：如果有文字，完整、准确地提取出来并尽量保留原有排版（表格用 Markdown 表格，代码用代码块）；最后用一两句话说明这张图片是什么。

            {query}
            """, enabled: true),
    ]

    static let disabled: [WebSearchEngine] = [
        .init(name: "纠错", kind: .aiPrompt, prompt: """
            检查下面文字中的错别字、标点、语法和用词错误。先输出修改后的全文，再用表格列出改动（原文 | 修改为 | 原因）；如果没有错误，直接回复“未发现错误”。

            {query}
            """, enabled: false),
        .init(name: "写成邮件", kind: .aiPrompt, prompt: """
            把下面的要点写成一封得体、简洁的工作邮件（语言与要点一致），包含主题、称呼、正文和结尾。语气专业友好，不要编造要点里没有的事实，缺少的信息用【】标出待填写。

            {query}
            """, enabled: false),
        .init(name: "提取待办", kind: .aiPrompt, prompt: """
            从下面的内容中提取所有待办事项，用任务列表输出（- [ ] 事项），有负责人和截止时间的一并注明；然后列出其他关键要点。没有待办时只列要点。

            {query}
            """, enabled: false),
        .init(name: "帮我回复", kind: .aiPrompt, prompt: """
            针对下面这条消息，写 3 条不同风格的回复供我选择：简洁、礼貌正式、轻松友好。语言与原消息一致，每条回复单独成段，前面用粗体标明风格。

            {query}
            """, enabled: false),
        .init(name: "起标题", kind: .aiPrompt, prompt: """
            为下面的内容起 5 个标题，风格各不相同（直接概括 / 吸引眼球 / 提问式 / 带数字 / 简短有力），每个不超过 25 字，用列表输出。

            {query}
            """, enabled: false),
        .init(name: "解释代码", kind: .aiPrompt, prompt: """
            解释下面这段代码：先用一句话说明它做什么，再分步骤说明关键逻辑，最后指出潜在的问题或可以改进的地方（如有）。

            {query}
            """, enabled: false),
        .init(name: "写正则", kind: .aiPrompt, prompt: """
            根据下面的需求写一个正则表达式：先在代码块里给出正则，再说明每一部分的含义，然后各给 2–3 个能匹配和不能匹配的例子。JavaScript / Python / Swift 写法有差别时请说明。

            需求：{query}
            """, enabled: false),
        .init(name: "Excel 公式", kind: .aiPrompt, prompt: """
            根据下面的需求写 Excel 公式：先在代码块里给出公式，再说明各参数的含义和用法；如果有更简洁的新函数写法（XLOOKUP、FILTER、LET 等）也一并给出，并说明 WPS 是否支持。

            需求：{query}
            """, enabled: false),
        .init(name: "终端命令", kind: .aiPrompt, prompt: """
            根据下面的需求给出 macOS 终端（zsh）命令，放在代码块里，并逐个解释参数。删除、覆盖、sudo 等有风险的操作要明确提醒。

            需求：{query}
            """, enabled: false),
    ]
}
