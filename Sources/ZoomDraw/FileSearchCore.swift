import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let fileSearchSettingsChanged = Notification.Name("ZoomDraw.fileSearchSettingsChanged")
}

// MARK: - 设置

enum FileSearchSettings {
    private static let d = UserDefaults.standard

    /// 默认排除：以 / 或 ~ 开头的是路径（含其下所有内容），其余按文件夹名匹配（任何位置）
    static let defaultExcludes = ["~/Library", "node_modules", "DerivedData", "Pods", "__pycache__", "site-packages"]
    static let maxResultChoices = [20, 40, 60, 100]

    static func registerDefaults() {
        d.register(defaults: [
            "filesearch.scopes": ["~"],
            "filesearch.excludes": defaultExcludes,
            "filesearch.excludedExts": [String](),
            "filesearch.maxResults": 40,
            "filesearch.snippets": true,
            "filesearch.showHidden": false,
            "filesearch.openFindKeywords": false,
            "filesearch.tagsKeyword": false,
            "filesearch.apps": true,
            "filesearch.preview": true,
        ])
    }

    private static func changed() {
        SearchRoots.invalidate()
        NotificationCenter.default.post(name: .fileSearchSettingsChanged, object: nil)
    }

    /// 搜索范围（保存为带 ~ 的路径）
    static var scopes: [String] {
        get { d.stringArray(forKey: "filesearch.scopes") ?? ["~"] }
        set { d.set(newValue, forKey: "filesearch.scopes"); changed() }
    }
    static var excludes: [String] {
        get { d.stringArray(forKey: "filesearch.excludes") ?? defaultExcludes }
        set { d.set(newValue, forKey: "filesearch.excludes"); changed() }
    }
    static var excludedExts: [String] {
        get { d.stringArray(forKey: "filesearch.excludedExts") ?? [] }
        set { d.set(newValue, forKey: "filesearch.excludedExts"); changed() }
    }
    /// 翻页键（默认 PageUp / PageDown，可在设置里改；没有这两个键的键盘可以用 fn+↑ / fn+↓ 或自定义组合）
    static let defaultPageUp = HotkeyBinding(keyCode: 116, modifiers: 0)
    static let defaultPageDown = HotkeyBinding(keyCode: 121, modifiers: 0)
    static var pageUpKey: HotkeyBinding {
        get { binding("filesearch.pageUp") ?? defaultPageUp }
        set { setBinding(newValue, "filesearch.pageUp") }
    }
    static var pageDownKey: HotkeyBinding {
        get { binding("filesearch.pageDown") ?? defaultPageDown }
        set { setBinding(newValue, "filesearch.pageDown") }
    }
    private static func binding(_ key: String) -> HotkeyBinding? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) }
    }
    private static func setBinding(_ b: HotkeyBinding, _ key: String) {
        if let data = try? JSONEncoder().encode(b) { d.set(data, forKey: key) }
        changed()
    }

    static var maxResults: Int {
        get { max(10, d.integer(forKey: "filesearch.maxResults")) }
        set { d.set(newValue, forKey: "filesearch.maxResults"); changed() }
    }
    static var snippets: Bool {
        get { d.bool(forKey: "filesearch.snippets") }
        set { d.set(newValue, forKey: "filesearch.snippets"); changed() }
    }
    static var showHidden: Bool {
        get { d.bool(forKey: "filesearch.showHidden") }
        set { d.set(newValue, forKey: "filesearch.showHidden"); changed() }
    }
    /// open / find 关键字（默认关闭：直接输入就是按名称搜索）
    static var openFindKeywords: Bool {
        get { d.bool(forKey: "filesearch.openFindKeywords") }
        set { d.set(newValue, forKey: "filesearch.openFindKeywords"); changed() }
    }
    static var tagsKeyword: Bool {
        get { d.bool(forKey: "filesearch.tagsKeyword") }
        set { d.set(newValue, forKey: "filesearch.tagsKeyword"); changed() }
    }
    static var searchApps: Bool {
        get { d.bool(forKey: "filesearch.apps") }
        set { d.set(newValue, forKey: "filesearch.apps"); changed() }
    }
    /// 搜索框右侧显示选中文件的预览（默认开启）
    static var preview: Bool {
        get { d.object(forKey: "filesearch.preview") == nil ? true : d.bool(forKey: "filesearch.preview") }
        set { d.set(newValue, forKey: "filesearch.preview"); changed() }
    }

    /// 最近用过的「移动到 / 复制到」目标文件夹
    static var recentTargets: [String] {
        get { (d.stringArray(forKey: "filesearch.recentTargets") ?? []).filter { isDirectory(expand($0)) } }
        set { d.set(Array(newValue.prefix(6)), forKey: "filesearch.recentTargets") }
    }
    static func addRecentTarget(_ path: String) {
        let p = abbreviate(path)
        recentTargets = [p] + recentTargets.filter { $0 != p }
    }

    static func expand(_ p: String) -> String {
        var s = (p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
    static func abbreviate(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

// MARK: - 排除规则

struct ExclusionRules {
    let paths: [String]
    let names: Set<String>
    let exts: Set<String>
    let roots: [String]

    /// 不展开查看内部的包（Spotlight 一般也不索引里面）
    static let bundleExts: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary",
                                          "xcarchive", "plugin", "kext", "appex", "lproj", "xcassets"]

    static var current: ExclusionRules {
        var paths: [String] = [], names = Set<String>()
        for raw in FileSearchSettings.excludes {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("/") || t.hasPrefix("~") { paths.append(FileSearchSettings.expand(t)) }
            else { names.insert(t.lowercased()) }
        }
        let exts = Set(FileSearchSettings.excludedExts.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        }.filter { !$0.isEmpty })
        return ExclusionRules(paths: paths, names: names, exts: exts,
                              roots: FileSearchSettings.scopes.map(FileSearchSettings.expand))
    }

    func excludes(path: String) -> Bool {
        for p in paths where path == p || path.hasPrefix(p + "/") { return true }
        // 只检查搜索范围以下的部分（范围本身在隐藏目录里也照常搜）
        var rel = Substring(path)
        if let root = roots.filter({ path.hasPrefix($0 == "/" ? "/" : $0 + "/") }).max(by: { $0.count < $1.count }) {
            rel = path.dropFirst(root == "/" ? 1 : root.count + 1)
        }
        let comps = rel.split(separator: "/")
        for (i, c) in comps.enumerated() {
            if c.hasPrefix(".") { return true }
            let lower = c.lowercased()
            if names.contains(lower) { return true }
            if i < comps.count - 1, let dot = lower.lastIndex(of: "."),
               Self.bundleExts.contains(String(lower[lower.index(after: dot)...])) { return true }
        }
        if !exts.isEmpty, let last = comps.last, let dot = last.lastIndex(of: ".") {
            if exts.contains(last[last.index(after: dot)...].lowercased()) { return true }
        }
        return false
    }
}

/// 实际交给 Spotlight 的搜索范围：
/// 范围内包含被排除的路径（如 ~/Library）时，把它展开成子文件夹，跳过被排除的部分；
/// 同时跳过挂载点 / 其他磁盘卷（例如 ~/OrbStack 这类虚拟文件系统会让查询卡住）
enum SearchRoots {
    private static var cache: (roots: [String], loose: [String], at: Date)?

    static func invalidate() { cache = nil }

    static func current() -> (roots: [String], loose: [String]) {
        if let c = cache, Date().timeIntervalSince(c.at) < 30 { return (c.roots, c.loose) }
        let rules = ExclusionRules.current
        var roots: [String] = [], loose: [String] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey, .isPackageKey]

        func volume(_ path: String) -> NSObject? {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        func expand(_ dir: String, depth: Int) {
            let containsExcluded = rules.paths.contains { $0.hasPrefix(dir == "/" ? "/" : dir + "/") }
            guard containsExcluded, depth < 4 else { roots.append(dir); return }
            loose.append(dir)
            let vol = volume(dir)
            let kids = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
            for k in kids {
                guard let v = try? k.resourceValues(forKeys: Set(keys)), v.isDirectory == true,
                      v.isSymbolicLink != true, v.isPackage != true else { continue }
                if let vol = vol, let kv = v.volumeIdentifier as? NSObject, !kv.isEqual(vol) { continue }
                let p = k.path
                if rules.excludes(path: p) { continue }
                expand(p, depth: depth + 1)
            }
        }
        for s in FileSearchSettings.scopes.map(FileSearchSettings.expand) where FileSearchSettings.isDirectory(s) {
            if rules.paths.contains(where: { s == $0 || s.hasPrefix($0 + "/") }) { continue }
            expand(s, depth: 0)
        }
        // 去掉被其他范围包含的重复项
        let uniq = Array(Set(roots)).sorted()
        let reduced = uniq.filter { r in !uniq.contains { $0 != r && r.hasPrefix($0 == "/" ? "/" : $0 + "/") } }
        cache = (reduced, loose, Date())
        return (reduced, loose)
    }
}

// MARK: - 名称匹配与打分

struct NameMatch {
    var score: Int
    var ranges: [NSRange]
}

enum NameMatcher {
    static let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// 所有关键词都要命中；返回分数（越高越好）和命中位置（用于高亮）
    static func match(_ name: String, tokens: [String], stem: String? = nil) -> NameMatch? {
        guard !tokens.isEmpty else { return NameMatch(score: 0, ranges: []) }
        let ns = name as NSString
        let stemLen = (stem.map { ($0 as NSString).length }) ?? ns.length
        var total = 0
        var ranges: [NSRange] = []
        for (i, t) in tokens.enumerated() {
            guard let (s, r) = matchOne(ns, stem: stem, stemLen: stemLen, token: t) else { return nil }
            total += i == 0 ? s : s / 4
            ranges += r
        }
        return NameMatch(score: total, ranges: ranges)
    }

    private static func matchOne(_ ns: NSString, stem: String?, stemLen: Int, token t: String) -> (Int, [NSRange])? {
        let tl = (t as NSString).length
        guard tl > 0 else { return (0, []) }
        if ns.compare(t, options: opts) == .orderedSame
            || (stem.map { ($0 as NSString).compare(t, options: opts) == .orderedSame } ?? false) {
            return (1000, [NSRange(location: 0, length: min(tl, ns.length))])
        }
        let anchored = ns.range(of: t, options: opts.union(.anchored))
        if anchored.location != NSNotFound {
            return (900 - min(max(stemLen - tl, 0), 80), [anchored])
        }
        var search = NSRange(location: 0, length: ns.length)
        var first: NSRange?
        while search.length > 0 {
            let r = ns.range(of: t, options: opts, range: search)
            if r.location == NSNotFound { break }
            if first == nil { first = r }
            if isBoundary(ns, r.location) { return (780 - min(r.location, 60), [r]) }
            let next = r.location + 1
            search = NSRange(location: next, length: ns.length - next)
        }
        if tl >= 2, let rs = acronym(ns, t) { return (720, rs) }
        if let f = first { return (600 - min(f.location, 80), [f]) }
        return nil
    }

    private static let separators = CharacterSet(charactersIn: " -_.()[]{}【】（）「」《》<>,，、+&@#/~!！:：;；'\"“”")

    static func isBoundary(_ ns: NSString, _ loc: Int) -> Bool {
        guard loc > 0 else { return true }
        guard let prev = UnicodeScalar(ns.character(at: loc - 1)), let cur = UnicodeScalar(ns.character(at: loc)) else { return false }
        if separators.contains(prev) { return true }
        let lower = CharacterSet.lowercaseLetters, upper = CharacterSet.uppercaseLetters, digits = CharacterSet.decimalDigits
        if lower.contains(prev) && upper.contains(cur) { return true }
        if digits.contains(prev) != digits.contains(cur) { return true }
        if isCJK(prev) != isCJK(cur) { return true }
        return false
    }

    static func isCJK(_ s: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x3040...0x30FF).contains(s.value)
            || (0xAC00...0xD7AF).contains(s.value)
    }

    /// 单词首字母：vsc → Visual Studio Code
    private static func acronym(_ ns: NSString, _ t: String) -> [NSRange]? {
        let tt = Array(t.lowercased().unicodeScalars)
        guard tt.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        var starts: [Int] = []
        for i in 0..<ns.length {
            guard let c = UnicodeScalar(ns.character(at: i)), CharacterSet.alphanumerics.contains(c), !isCJK(c) else { continue }
            if isBoundary(ns, i) { starts.append(i) }
        }
        guard starts.count >= tt.count else { return nil }
        var ranges: [NSRange] = []
        var j = 0
        for s in starts where j < tt.count {
            guard let c = UnicodeScalar(ns.character(at: s)) else { return nil }
            if String(c).lowercased().unicodeScalars.first == tt[j] {
                ranges.append(NSRange(location: s, length: 1)); j += 1
            } else if j == 0 {
                return nil   // 第一个字母必须是第一个单词的首字母
            } else {
                continue
            }
        }
        return j == tt.count ? ranges : nil
    }
}

// MARK: - 使用记忆（Alfred 式：在某个输入下选过的结果，下次排到前面）

final class FileSearchUsage {
    static let shared = FileSearchUsage()

    struct Entry: Codable {
        var count: Int
        var last: Date
        var queries: [String: Int]
    }

    private(set) var entries: [String: Entry] = [:]
    private var dirty = false

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoomDraw", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("filesearch-usage.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let e = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = e }
    }

    static func key(_ query: String) -> String {
        String(query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))
    }

    func record(path: String, query: String) {
        let k = Self.key(query)
        var e = entries[path] ?? Entry(count: 0, last: Date(), queries: [:])
        e.count += 1
        e.last = Date()
        if !k.isEmpty { e.queries[k, default: 0] += 1 }
        if e.queries.count > 12 {
            e.queries = Dictionary(uniqueKeysWithValues: e.queries.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) })
        }
        entries[path] = e
        if entries.count > 3000 {
            let keep = entries.sorted { $0.value.last > $1.value.last }.prefix(2500)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        scheduleSave()
    }

    func boost(path: String, query: String) -> Int { Self.boost(entries, path: path, query: query) }

    /// 纯函数版本：可在后台线程用 entries 的副本计算
    static func boost(_ entries: [String: Entry], path: String, query: String) -> Int {
        guard let e = entries[path] else { return 0 }
        let k = key(query)
        var b = min(e.count, 30) * 6
        var best = 0
        for (q, c) in e.queries {
            if q == k { best = max(best, 600 + min(c, 20) * 20) }
            else if !k.isEmpty && (q.hasPrefix(k) || k.hasPrefix(q)) { best = max(best, 300 + min(c, 20) * 10) }
        }
        b += best
        let age = Date().timeIntervalSince(e.last)
        if age < 86400 { b += 40 } else if age < 7 * 86400 { b += 20 }
        return b
    }

    /// 记忆里名字命中的路径（不在 Spotlight 索引里的也能找到）
    func candidates(tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        return entries.keys.filter { p in
            let name = (p as NSString).lastPathComponent
            return tokens.allSatisfy { name.range(of: $0, options: NameMatcher.opts) != nil }
        }
    }

    func clear() {
        entries = [:]
        scheduleSave()
    }

    func remove(path: String) {
        entries[path] = nil
        scheduleSave()
    }

    private func scheduleSave() {
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.flush() }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - 应用程序目录

final class AppCatalog {
    static let shared = AppCatalog()

    struct App {
        let url: URL
        let name: String
        let names: [String]
        let bundleID: String?
    }

    private(set) var apps: [App] = []
    private var lastScan = Date.distantPast
    private var scanning = false

    private static var scanDirs: [String] {
        ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications",
         "/System/Library/CoreServices/Applications"]
    }
    private static let extraApps = ["/System/Library/CoreServices/Finder.app"]

    func refreshIfNeeded(force: Bool = false) {
        guard !scanning, force || Date().timeIntervalSince(lastScan) > 120 else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let list = Self.scan()
            DispatchQueue.main.async {
                self.apps = list
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    /// 同步扫描（首次打开搜索框、列表还是空的时候用）
    func ensureLoaded() {
        guard apps.isEmpty else { refreshIfNeeded(); return }
        apps = Self.scan()
        lastScan = Date()
    }

    private static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [App] = []

        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary ?? [:]
            if let bid = bundle?.bundleIdentifier, out.contains(where: { $0.bundleID == bid && $0.url.path == url.path }) { return }
            var display = fm.displayName(atPath: url.path)
            if display.lowercased().hasSuffix(".app") { display = String(display.dropLast(4)) }
            let stem = url.deletingPathExtension().lastPathComponent
            var names = [display, stem]
            for k in ["CFBundleDisplayName", "CFBundleName"] {
                if let s = bundle?.localizedInfoDictionary?[k] as? String { names.append(s) }
                if let s = info[k] as? String { names.append(s) }
            }
            var uniq: [String] = []
            for n in names where !n.isEmpty && !uniq.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                uniq.append(n)
            }
            out.append(App(url: url, name: display, names: uniq, bundleID: bundle?.bundleIdentifier))
        }
        func walk(_ dir: URL, depth: Int) {
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return }
            for k in kids {
                if k.pathExtension.lowercased() == "app" { add(k); continue }
                if depth < 2, (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walk(k, depth: depth + 1)
                }
            }
        }
        for d in scanDirs { walk(URL(fileURLWithPath: d), depth: 0) }
        for p in extraApps where fm.fileExists(atPath: p) { add(URL(fileURLWithPath: p)) }
        return out
    }

    func search(tokens: [String]) -> [(App, NameMatch)] {
        var out: [(App, NameMatch)] = []
        for a in apps {
            var best: NameMatch?
            for (i, n) in a.names.enumerated() {
                guard var m = NameMatcher.match(n, tokens: tokens) else { continue }
                if i > 0 { m.ranges = [] }   // 只有显示的名字才高亮
                if best == nil || m.score > best!.score { best = m }
            }
            if let b = best {
                // 高亮显示名里的命中位置
                let shown = NameMatcher.match(a.name, tokens: tokens)
                out.append((a, NameMatch(score: b.score, ranges: shown?.ranges ?? [])))
            }
        }
        return out
    }
}

// MARK: - Spotlight 查询（异步、渐进返回）

struct FileHit {
    let path: String
}

final class SpotlightRunner {
    enum Mode { case name, content, tags, folders }

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var budgetTimer: Timer?
    private var throttleTimer: Timer?
    private var read = 0
    private var cap = 0
    private var hits: [FileHit] = []
    private var onUpdate: (([FileHit], Bool) -> Void)?
    private var lastEmit = Date.distantPast

    var isRunning: Bool { query != nil }

    static func escape(_ t: String) -> String {
        t.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "*", with: "\\*")
    }

    static func queryString(_ mode: Mode, tokens: [String]) -> String {
        let attr: String
        switch mode {
        case .name: attr = "kMDItemFSName"
        case .content: attr = "kMDItemTextContent"
        case .tags: attr = "kMDItemUserTags"
        case .folders: attr = "kMDItemFSName"
        }
        var q = tokens.map { "\(attr) == \"*\(escape($0))*\"cd" }.joined(separator: " && ")
        if mode == .folders { q += " && kMDItemContentType == \"public.folder\"" }
        return q
    }

    /// onUpdate(全部结果, 是否已结束)；每次回调都在主线程
    func start(_ mode: Mode, tokens: [String], roots: [String], cap: Int, budget: TimeInterval,
               onUpdate: @escaping ([FileHit], Bool) -> Void) {
        stop()
        guard !tokens.isEmpty, !roots.isEmpty,
              let pred = NSPredicate(fromMetadataQueryString: Self.queryString(mode, tokens: tokens)) else {
            onUpdate([], true); return
        }
        let q = NSMetadataQuery()
        q.predicate = pred
        q.searchScopes = roots
        q.notificationBatchingInterval = 0.08
        self.query = q
        self.cap = cap
        self.read = 0
        self.hits = []
        self.onUpdate = onUpdate
        self.lastEmit = Date()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: .main) { [weak self] _ in
            self?.progress(final: false)
        })
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            self?.progress(final: true)
        })
        budgetTimer = Timer.scheduledTimer(withTimeInterval: budget, repeats: false) { [weak self] _ in
            self?.progress(final: true)
        }
        if !q.start() { finish() }
    }

    private func progress(final: Bool) {
        guard let q = query else { return }
        q.disableUpdates()
        let n = min(q.resultCount, cap)
        while read < n {
            if let item = q.result(at: read) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                // 只读路径：逐条读时间属性很慢（3000 条约 2 秒），时间加成改为排序后只对前几十条补读
                hits.append(FileHit(path: path))
            }
            read += 1
        }
        q.enableUpdates()
        if final || read >= cap {
            finish()
            return
        }
        // 渐进结果最多每 0.15 秒刷新一次
        if Date().timeIntervalSince(lastEmit) > 0.15 {
            lastEmit = Date()
            onUpdate?(hits, false)
        } else if throttleTimer == nil {
            throttleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.throttleTimer = nil
                self.lastEmit = Date()
                if self.query != nil { self.onUpdate?(self.hits, false) }
            }
        }
    }

    private func finish() {
        let cb = onUpdate
        let result = hits
        stop()
        cb?(result, true)
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        budgetTimer?.invalidate(); budgetTimer = nil
        throttleTimer?.invalidate(); throttleTimer = nil
        onUpdate = nil
    }
}
