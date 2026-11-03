import AppKit
import CryptoKit
import ImageIO

// MARK: - 模型

enum ClipKind: String, Codable {
    case text, link, color, image, file
}

struct ClipItem: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: ClipKind
    /// 用于搜索与列表展示的纯文本（超长文本会截断；完整内容在 payload 中）
    var text: String
    /// 文件条目的路径
    var paths: [String]?
    /// 是否存有原始剪贴板数据（富文本等，用于原样还原）
    var hasPayload: Bool
    var imageWidth: Int?
    var imageHeight: Int?
    /// 原始数据大小（字节）
    var byteSize: Int
    /// 内容摘要，用于去重
    var digest: String
    var sourceBundleID: String?
    var sourceName: String?
    var createdAt: Date
    /// 最近一次复制 / 使用时间，列表按此排序
    var lastUsedAt: Date
    var pinned: Bool
    var pinnedAt: Date?
    var copyCount: Int

    var fileURLs: [URL] { (paths ?? []).map { URL(fileURLWithPath: $0) } }
    var existingFileURLs: [URL] { fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }

    /// 列表标题：第一行非空文本
    var title: String {
        switch kind {
        case .image:
            if let w = imageWidth, let h = imageHeight { return "图片  \(w) × \(h)" }
            return "图片"
        case .file:
            let urls = fileURLs
            guard let first = urls.first else { return "文件" }
            return urls.count > 1 ? "\(first.lastPathComponent) 等 \(urls.count) 个文件" : first.lastPathComponent
        default:
            let line = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? text
            return String(line.prefix(300))
        }
    }

    var color: NSColor? { kind == .color ? ClipItem.parseColor(text) : nil }

    static func parseColor(_ raw: String) -> NSColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard [3, 6, 8].contains(s.count), s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255;  a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255;         a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension Notification.Name {
    /// 历史条目增删改
    static let clipboardHistoryChanged = Notification.Name("ZoomDraw.clipboardHistoryChanged")
    /// 启用 / 暂停状态变化（菜单栏需要刷新）
    static let clipboardStateChanged = Notification.Name("ZoomDraw.clipboardStateChanged")
}

// MARK: - 设置

enum ClipboardSettings {
    private static let d = UserDefaults.standard

    static let maxItemsOptions = [50, 100, 200, 500, 1000]
    /// 0 = 永久
    static let maxDaysOptions = [1, 7, 30, 90, 0]

    static let defaultIgnoredApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
    ]

    static func registerDefaults() {
        d.register(defaults: [
            "clipboard.enabled": true,
            "clipboard.recordText": true,
            "clipboard.recordImages": true,
            "clipboard.recordFiles": true,
            "clipboard.maxItems": 200,
            "clipboard.maxDays": 30,
            "clipboard.autoPaste": true,
            "clipboard.plainTextDefault": false,
            "clipboard.ignoredApps": defaultIgnoredApps,
        ])
    }

    static var enabled: Bool {
        get { d.bool(forKey: "clipboard.enabled") }
        set {
            d.set(newValue, forKey: "clipboard.enabled")
            ClipboardStore.shared.updateMonitor()
            NotificationCenter.default.post(name: .clipboardStateChanged, object: nil)
        }
    }
    static var recordText: Bool {
        get { d.bool(forKey: "clipboard.recordText") }
        set { d.set(newValue, forKey: "clipboard.recordText") }
    }
    static var recordImages: Bool {
        get { d.bool(forKey: "clipboard.recordImages") }
        set { d.set(newValue, forKey: "clipboard.recordImages") }
    }
    static var recordFiles: Bool {
        get { d.bool(forKey: "clipboard.recordFiles") }
        set { d.set(newValue, forKey: "clipboard.recordFiles") }
    }
    static var maxItems: Int {
        get { max(10, d.integer(forKey: "clipboard.maxItems")) }
        set { d.set(newValue, forKey: "clipboard.maxItems"); ClipboardStore.shared.applyRetention() }
    }
    static var maxDays: Int {
        get { max(0, d.integer(forKey: "clipboard.maxDays")) }
        set { d.set(newValue, forKey: "clipboard.maxDays"); ClipboardStore.shared.applyRetention() }
    }
    static var autoPaste: Bool {
        get { d.bool(forKey: "clipboard.autoPaste") }
        set { d.set(newValue, forKey: "clipboard.autoPaste") }
    }
    static var plainTextDefault: Bool {
        get { d.bool(forKey: "clipboard.plainTextDefault") }
        set { d.set(newValue, forKey: "clipboard.plainTextDefault") }
    }
    static var ignoredApps: [String] {
        get { d.stringArray(forKey: "clipboard.ignoredApps") ?? defaultIgnoredApps }
        set { d.set(newValue, forKey: "clipboard.ignoredApps") }
    }
}

// MARK: - 存储与监听

final class ClipboardStore {
    static let shared = ClipboardStore()

    /// 自己写入剪贴板时打的标记，监听时跳过
    static let ownMarker = NSPasteboard.PasteboardType("com.zoomdraw.clipboard-history")

    /// 密码管理器等标记为「不应被记录」的类型（nspasteboard.org 约定）
    private static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "net.antelle.keeweb",
    ]

    /// 还原时无意义或会出错的类型
    private static let skipPayloadTypes: Set<String> = [
        ownMarker.rawValue,
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.NSFilePromiseItemMetaData",
        "NSPromiseContentsPboardType",
    ]

    private static let maxIndexedChars = 20_000
    private static let maxTypeBytes = 20 * 1024 * 1024
    private static let maxPayloadBytes = 40 * 1024 * 1024
    private static let maxImageBytes = 30 * 1024 * 1024

    /// 已排序：固定的在前（按固定先后），其余按最近使用倒序
    private(set) var items: [ClipItem] = []

    private let fm = FileManager.default
    private let dataDir: URL
    private let indexURL: URL
    private let work = DispatchQueue(label: "ZoomDraw.clipboard", qos: .utility)

    private var pollTimer: Timer?
    private var pruneTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var saveWork: DispatchWorkItem?
    private var started = false

    private(set) var pausedUntil: Date?
    var isPaused: Bool {
        guard let p = pausedUntil else { return false }
        return p > Date()
    }

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("ZoomDraw", isDirectory: true)
        dataDir = root.appendingPathComponent("Clipboard", isDirectory: true)
        indexURL = root.appendingPathComponent("clipboard.json")
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    // MARK: 生命周期

    func startup() {
        guard !started else { return }
        started = true
        ClipboardSettings.registerDefaults()
        load()
        removeOrphanFiles()
        applyRetention()
        updateMonitor()
        // 按时长清理：每 30 分钟检查一次
        let t = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in self?.applyRetention() }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    func updateMonitor() {
        if ClipboardSettings.enabled {
            guard pollTimer == nil else { return }
            lastChangeCount = NSPasteboard.general.changeCount
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// 退出前同步落盘
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        writeIndex(snapshot: items)
    }

    // MARK: 暂停

    /// minutes 为 nil 表示直到手动恢复
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        NotificationCenter.default.post(name: .clipboardStateChanged, object: nil)
    }

    func resume() {
        pausedUntil = nil
        lastChangeCount = NSPasteboard.general.changeCount
        NotificationCenter.default.post(name: .clipboardStateChanged, object: nil)
    }

    // MARK: 监听

    private func poll() {
        if let p = pausedUntil, p <= Date() {
            pausedUntil = nil
            NotificationCenter.default.post(name: .clipboardStateChanged, object: nil)
        }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard ClipboardSettings.enabled, !isPaused else { return }
        capture(pb)
    }

    private func capture(_ pb: NSPasteboard) {
        guard let types = pb.types, !types.isEmpty else { return }
        let typeSet = Set(types.map(\.rawValue))
        if typeSet.contains(Self.ownMarker.rawValue) { return }
        if !typeSet.isDisjoint(with: Self.sensitiveTypes) { return }

        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        if let bid = bundleID, ClipboardSettings.ignoredApps.contains(bid) { return }
        let source = (bundleID, front?.localizedName)

        // 1) 文件
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            guard ClipboardSettings.recordFiles else { return }
            let paths = urls.map { $0.standardizedFileURL.path }
            let joined = paths.joined(separator: "\n")
            commit(kind: .file, text: joined, paths: paths, digest: Self.sha("f:" + joined),
                   byteSize: 0, source: source)
            return
        }

        // 2) 文本（含富文本）
        var plain = pb.string(forType: .string)
        if plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            plain = Self.plainTextFromRich(pb)
        }
        if let plain = plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard ClipboardSettings.recordText else { return }
            let payload = snapshotPayload(pb)
            work.async { [weak self] in
                let digest = Self.sha("t:" + plain)
                let payloadData = payload.isEmpty ? nil
                    : try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
                let size = payload.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
                let kind = Self.classify(plain)
                let indexed = plain.count > Self.maxIndexedChars ? String(plain.prefix(Self.maxIndexedChars)) : plain
                DispatchQueue.main.async {
                    self?.commit(kind: kind, text: indexed, paths: nil, digest: digest,
                                 byteSize: size, source: source, payload: payloadData)
                }
            }
            return
        }

        // 3) 图片
        guard ClipboardSettings.recordImages else { return }
        let png = pb.data(forType: .png)
        var other: Data? = png == nil ? pb.data(forType: .tiff) : nil
        if png == nil, other == nil, let img = NSImage(pasteboard: pb) {
            other = img.tiffRepresentation
        }
        guard png != nil || other != nil else { return }
        work.async { [weak self] in
            let pngData: Data?
            if let png = png { pngData = png }
            else if let raw = other, let rep = NSBitmapImageRep(data: raw) {
                pngData = rep.representation(using: .png, properties: [:])
            } else { pngData = nil }
            guard let data = pngData, data.count <= Self.maxImageBytes else { return }
            let (w, h) = Self.pixelSize(of: data)
            let thumb = Self.makeThumbnail(from: data, maxPixel: 160)
            let digest = Self.sha(data: data)
            DispatchQueue.main.async {
                self?.commit(kind: .image, text: "", paths: nil, digest: digest, byteSize: data.count,
                             source: source, image: (data, thumb, w, h))
            }
        }
    }

    /// 把当前剪贴板的全部类型拷贝一份，用于原样还原
    private func snapshotPayload(_ pb: NSPasteboard) -> [[String: Data]] {
        var result: [[String: Data]] = []
        var total = 0
        for item in pb.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for t in item.types where !Self.skipPayloadTypes.contains(t.rawValue) {
                guard let data = item.data(forType: t) else { continue }
                guard data.count <= Self.maxTypeBytes, total + data.count <= Self.maxPayloadBytes else { continue }
                dict[t.rawValue] = data
                total += data.count
            }
            if !dict.isEmpty { result.append(dict) }
        }
        return result
    }

    private func commit(kind: ClipKind, text: String, paths: [String]?, digest: String,
                        byteSize: Int, source: (String?, String?),
                        payload: Data? = nil,
                        image: (Data, Data?, Int, Int)? = nil) {
        let now = Date()
        if let idx = items.firstIndex(where: { $0.digest == digest && $0.kind == kind }) {
            var it = items[idx]
            it.lastUsedAt = now
            it.copyCount += 1
            it.sourceBundleID = source.0
            it.sourceName = source.1
            if let payload = payload {
                writeFile(payload, to: payloadURL(it.id))
                it.hasPayload = true
                it.byteSize = byteSize
            }
            items[idx] = it
        } else {
            let id = UUID()
            var it = ClipItem(id: id, kind: kind, text: text, paths: paths,
                              hasPayload: payload != nil, imageWidth: nil, imageHeight: nil,
                              byteSize: byteSize, digest: digest,
                              sourceBundleID: source.0, sourceName: source.1,
                              createdAt: now, lastUsedAt: now,
                              pinned: false, pinnedAt: nil, copyCount: 1)
            if let payload = payload { writeFile(payload, to: payloadURL(id)) }
            if let (png, thumb, w, h) = image {
                writeFile(png, to: imageURL(id))
                if let thumb = thumb { writeFile(thumb, to: thumbURL(id)) }
                it.imageWidth = w
                it.imageHeight = h
            }
            items.append(it)
        }
        sortItems()
        enforceRetention()
        changed()
    }

    // MARK: 对外操作

    func item(id: UUID) -> ClipItem? { items.first { $0.id == id } }

    func togglePin(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        items[idx].pinnedAt = items[idx].pinned ? Date() : nil
        sortItems()
        changed()
    }

    func remove(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        deleteFiles(of: [items[idx]])
        items.remove(at: idx)
        changed()
    }

    /// 清除最近 N 分钟（nil = 全部）的未固定条目
    func clear(lastMinutes: Int?) {
        let cutoff = lastMinutes.map { Date().addingTimeInterval(-TimeInterval($0 * 60)) }
        let removed = items.filter { !$0.pinned && (cutoff == nil || $0.lastUsedAt >= cutoff!) }
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        deleteFiles(of: removed)
        items.removeAll { ids.contains($0.id) }
        changed()
    }

    func applyRetention() {
        guard started else { return }
        if enforceRetention() { changed() }
    }

    /// 写回系统剪贴板；成功后条目移到最前
    @discardableResult
    func writeToPasteboard(_ item: ClipItem, plainText: Bool) -> Bool {
        var pbItems: [NSPasteboardItem] = []
        switch item.kind {
        case .file:
            let urls = item.existingFileURLs
            guard !urls.isEmpty else { return false }
            if plainText {
                let i = NSPasteboardItem()
                i.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                pbItems = [i]
            } else {
                for url in urls {
                    let i = NSPasteboardItem()
                    i.setString(url.absoluteString, forType: .fileURL)
                    i.setString(url.lastPathComponent, forType: .string)
                    pbItems.append(i)
                }
            }
        case .image:
            guard let png = try? Data(contentsOf: imageURL(item.id)) else { return false }
            let i = NSPasteboardItem()
            i.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                i.setData(tiff, forType: .tiff)
            }
            pbItems = [i]
        case .text, .link, .color:
            if !plainText, item.hasPayload, let payload = payload(for: item.id), !payload.isEmpty {
                for dict in payload {
                    let i = NSPasteboardItem()
                    for (type, data) in dict {
                        i.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                    pbItems.append(i)
                }
            } else {
                let i = NSPasteboardItem()
                i.setString(fullText(of: item), forType: .string)
                pbItems = [i]
            }
        }
        guard let first = pbItems.first else { return false }
        first.setData(Data(), forType: Self.ownMarker)

        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects(pbItems) else { return false }
        lastChangeCount = pb.changeCount

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].lastUsedAt = Date()
            sortItems()
            changed()
        }
        return true
    }

    /// 完整纯文本（列表里的 text 可能被截断）
    func fullText(of item: ClipItem) -> String {
        guard item.kind != .image, item.kind != .file else { return item.text }
        if item.hasPayload, let payload = payload(for: item.id) {
            for dict in payload {
                if let d = dict[NSPasteboard.PasteboardType.string.rawValue],
                   let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
            }
        }
        return item.text
    }

    // MARK: 文件

    func imageURL(_ id: UUID) -> URL { dataDir.appendingPathComponent("\(id.uuidString).png") }
    func thumbURL(_ id: UUID) -> URL { dataDir.appendingPathComponent("\(id.uuidString).thumb.png") }
    private func payloadURL(_ id: UUID) -> URL { dataDir.appendingPathComponent("\(id.uuidString).payload") }

    func payload(for id: UUID) -> [[String: Data]]? {
        guard let data = try? Data(contentsOf: payloadURL(id)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Data]]
    }

    private func writeFile(_ data: Data, to url: URL) {
        let fm = self.fm
        work.async {
            fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private func deleteFiles(of removed: [ClipItem]) {
        let urls = removed.flatMap { [payloadURL($0.id), imageURL($0.id), thumbURL($0.id)] }
        let fm = self.fm
        work.async {
            for u in urls where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }
    }

    /// 启动时删掉索引里已不存在的条目留下的数据文件
    private func removeOrphanFiles() {
        let ids = Set(items.map { $0.id.uuidString })
        let dir = dataDir
        let fm = self.fm
        work.async {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                let stem = String(name.prefix(36))
                if !ids.contains(stem) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            }
        }
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode([ClipItem].self, from: data) else { return }
        items = decoded.filter { $0.kind != .image || fm.fileExists(atPath: imageURL($0.id).path) }
        sortItems()
    }

    private func changed() {
        scheduleSave()
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.saveWork = nil
            let snapshot = self.items
            self.work.async { self.writeIndex(snapshot: snapshot) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func writeIndex(snapshot: [ClipItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    // MARK: 排序与保留

    private func sortItems() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.pinned { return (a.pinnedAt ?? .distantPast) < (b.pinnedAt ?? .distantPast) }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    /// 按条数 / 时长清理未固定条目；返回是否有删除
    @discardableResult
    private func enforceRetention() -> Bool {
        var removed: [ClipItem] = []
        let days = ClipboardSettings.maxDays
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
            removed += items.filter { !$0.pinned && $0.lastUsedAt < cutoff }
        }
        let removedIDs = Set(removed.map(\.id))
        let unpinned = items.filter { !$0.pinned && !removedIDs.contains($0.id) }
        let limit = ClipboardSettings.maxItems
        if unpinned.count > limit {
            removed += unpinned[limit...]
        }
        guard !removed.isEmpty else { return false }
        let ids = Set(removed.map(\.id))
        deleteFiles(of: removed)
        items.removeAll { ids.contains($0.id) }
        return true
    }

    // MARK: 工具

    private static func classify(_ text: String) -> ClipKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipItem.parseColor(t) != nil { return .color }
        if !t.contains(where: { $0.isWhitespace }), t.count < 4096,
           let url = URL(string: t), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme), url.host != nil {
            return .link
        }
        return .text
    }

    private static func plainTextFromRich(_ pb: NSPasteboard) -> String? {
        if let rtf = pb.data(forType: .rtf),
           let s = NSAttributedString(rtf: rtf, documentAttributes: nil) { return s.string }
        if let html = pb.data(forType: .html),
           let s = NSAttributedString(html: html, documentAttributes: nil) { return s.string }
        return nil
    }

    private static func sha(_ s: String) -> String { sha(data: Data(s.utf8)) }

    private static func sha(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pixelSize(of data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (w, h)
    }

    private static func makeThumbnail(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
