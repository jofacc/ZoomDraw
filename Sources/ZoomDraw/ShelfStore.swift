import AppKit
import UniformTypeIdentifiers

/// 暂存板中的一项
struct ShelfItem: Codable, Equatable, Identifiable {
    let id: UUID
    /// 文件路径。外部拖入的文件保留原路径；文本/图片等会先落盘到暂存目录
    var path: String
    /// 是否由暂存板自己生成（落盘的文本/图片），移除时可一并删除文件
    var isManaged: Bool
    var addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    init(path: String, isManaged: Bool) {
        self.id = UUID()
        self.path = path
        self.isManaged = isManaged
        self.addedAt = Date()
    }
}

extension Notification.Name {
    static let shelfChanged = Notification.Name("ZoomDraw.shelfChanged")
}

/// 暂存板数据仓库：负责落盘、持久化与去重
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var items: [ShelfItem] = []

    private let fm = FileManager.default
    private let indexURL: URL
    /// 落盘目录：~/Library/Application Support/ZoomDraw/Shelf
    private let storageDir: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("ZoomDraw", isDirectory: true)
        storageDir = root.appendingPathComponent("Shelf", isDirectory: true)
        indexURL = root.appendingPathComponent("shelf.json")
        try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        load()
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    // MARK: - 读写
    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        // 启动时清掉已被移动/删除的文件条目
        items = decoded.filter { $0.exists }
        if items.count != decoded.count { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func changed() {
        persist()
        NotificationCenter.default.post(name: .shelfChanged, object: nil)
    }

    // MARK: - 增删
    /// 追加文件路径，返回实际新增的条目数
    @discardableResult
    func addFiles(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard fm.fileExists(atPath: path) else { continue }
            guard !items.contains(where: { $0.path == path }) else { continue }
            items.insert(ShelfItem(path: path, isManaged: false), at: 0)
            added += 1
        }
        if added > 0 { changed() }
        return added
    }

    /// 纯文本 → .txt
    @discardableResult
    func addText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let name = Self.safeFileName(from: trimmed, fallback: "文本") + ".txt"
        guard let url = uniqueURL(for: name) else { return false }
        guard (try? trimmed.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        items.insert(ShelfItem(path: url.path, isManaged: true), at: 0)
        changed()
        return true
    }

    /// 图片数据 → .png
    @discardableResult
    func addImage(_ image: NSImage, suggestedName: String? = nil) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let base = suggestedName ?? "图片 \(Self.timestamp())"
        guard let url = uniqueURL(for: base + ".png") else { return false }
        guard (try? png.write(to: url)) != nil else { return false }
        items.insert(ShelfItem(path: url.path, isManaged: true), at: 0)
        changed()
        return true
    }

    /// 网址 → .webloc（Finder 原生可识别）
    @discardableResult
    func addLink(_ link: URL) -> Bool {
        let plist: [String: Any] = ["URL": link.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                            format: .xml, options: 0) else { return false }
        let base = Self.safeFileName(from: link.host ?? "链接", fallback: "链接")
        guard let url = uniqueURL(for: base + ".webloc") else { return false }
        guard (try? data.write(to: url)) != nil else { return false }
        items.insert(ShelfItem(path: url.path, isManaged: true), at: 0)
        changed()
        return true
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) && item.isManaged {
            try? fm.removeItem(at: item.url)
        }
        items.removeAll { ids.contains($0.id) }
        changed()
    }

    func removeAll() {
        for item in items where item.isManaged {
            try? fm.removeItem(at: item.url)
        }
        items.removeAll()
        changed()
    }

    /// 清理已失效（源文件被移动或删除）的条目
    @discardableResult
    func pruneMissing() -> Int {
        let before = items.count
        items.removeAll { !$0.exists }
        let removed = before - items.count
        if removed > 0 { changed() }
        return removed
    }

    // MARK: - 从剪贴板 / 拖拽面板导入
    /// 解析拖拽或剪贴板内容并入库，返回新增条目数
    @discardableResult
    func ingest(from pasteboard: NSPasteboard) -> Int {
        // 1) 文件优先
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return addFiles(urls)
        }
        // 2) 图片
        if let image = NSImage(pasteboard: pasteboard) {
            return addImage(image) ? 1 : 0
        }
        // 3) 网址
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let link = urls.first, link.scheme?.hasPrefix("http") == true {
            return addLink(link) ? 1 : 0
        }
        // 4) 纯文本
        if let text = pasteboard.string(forType: .string) {
            return addText(text) ? 1 : 0
        }
        return 0
    }

    /// 暂存板能接收的拖拽类型
    static var acceptedDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .png, .tiff, .pdf, .rtf, .string]
    }

    // MARK: - 工具
    private func uniqueURL(for name: String) -> URL? {
        try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        var candidate = storageDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        for i in 2...999 {
            candidate = storageDir.appendingPathComponent("\(stem) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func safeFileName(from raw: String, fallback: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let cleaned = firstLine.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let clipped = String(cleaned.prefix(40))
        return clipped.isEmpty ? fallback : clipped
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
