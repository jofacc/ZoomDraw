import AppKit
import PDFKit
import UniformTypeIdentifiers

/// 正文命中片段：从文件里找到关键词所在的那一句
enum FileSnippet {
    struct Result {
        let text: String
        let ranges: [NSRange]
    }

    /// nil：这种格式读不出文字；.some(nil)：读出来了但没找到关键词（Spotlight 命中的可能是元数据）
    private static var cache: [String: Result?] = [:]
    private static var pending: [String: [(Result?) -> Void]] = [:]
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    static let unsupportedExts: Set<String> = ["pages", "numbers", "key", "xls", "ppt", "zip", "dmg", "app"]

    /// 在主线程调用、主线程回调
    static func load(_ url: URL, tokens: [String], completion: @escaping (Result?) -> Void) {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(tokens.joined(separator: "\u{1}"))"
        if let hit = cache[key] { completion(hit); return }
        if pending[key] != nil { pending[key]!.append(completion); return }
        pending[key] = [completion]
        queue.addOperation {
            let text = extractText(url, tokens: tokens)
            let r = text.flatMap { makeSnippet($0, tokens: tokens) }
            DispatchQueue.main.async {
                if cache.count > 800 { cache.removeAll() }
                cache.updateValue(r, forKey: key)
                let cbs = pending.removeValue(forKey: key) ?? []
                cbs.forEach { $0(r) }
            }
        }
    }

    // MARK: 提取文字

    private static let textExts: Set<String> = [
        "txt", "text", "md", "markdown", "mdx", "rst", "org", "log", "csv", "tsv", "json", "jsonl", "xml", "yaml", "yml",
        "toml", "ini", "conf", "cfg", "env", "properties", "plist", "strings", "sql", "srt", "vtt", "tex", "bib",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "scala", "go", "rs", "py", "rb", "php",
        "pl", "lua", "r", "dart", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "css", "scss", "less", "sass",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "gradle", "cmake", "make", "mk", "dockerfile", "gitignore",
        "proto", "graphql", "ipynb", "svg",
    ]

    static func extractText(_ url: URL, tokens: [String]) -> String? {
        let ext = url.pathExtension.lowercased()
        if unsupportedExts.contains(ext) { return nil }
        switch ext {
        case "pdf":
            return pdfText(url, tokens: tokens)
        case "docx", "docm", "dotx":
            return unzipXML(url, member: "word/document.xml", paragraphTag: "</w:p>")
        case "xlsx", "xlsm":
            return unzipXML(url, member: "xl/sharedStrings.xml", paragraphTag: "</si>")
        case "pptx":
            return unzipXML(url, member: "ppt/slides/slide*.xml", paragraphTag: "</a:p>")
        case "doc", "rtf", "rtfd", "odt", "wordml":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        case "html", "htm", "xhtml", "webarchive":
            guard ext != "webarchive", let s = readText(url, limit: 4_000_000) else { return nil }
            return stripTags(s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                                     options: .regularExpression))
        default:
            break
        }
        let isText = textExts.contains(ext)
            || (UTType(filenameExtension: ext).map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) } ?? false)
            || (ext.isEmpty && looksLikeText(url))
        return isText ? readText(url, limit: 8_000_000) : nil
    }

    private static func readText(_ url: URL, limit: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: limit), !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        // 截断处可能切开了多字节字符：去掉末尾几个字节再试
        for cut in 1...3 where data.count > cut {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return nil
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4096), !d.isEmpty else { return false }
        return !d.contains(0)
    }

    private static func pdfText(_ url: URL, tokens: [String]) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked { return nil }
        let n = min(doc.pageCount, 400)
        var firstText: String?
        for i in 0..<n {
            guard let s = doc.page(at: i)?.string, !s.isEmpty else { continue }
            if firstText == nil { firstText = s }
            if tokens.contains(where: { s.range(of: $0, options: NameMatcher.opts) != nil }) { return s }
        }
        return firstText
    }

    private static func unzipXML(_ url: URL, member: String, paragraphTag: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, member]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard !data.isEmpty, let xml = String(data: data.prefix(20_000_000), encoding: .utf8) else { return nil }
        return stripTags(xml.replacingOccurrences(of: paragraphTag, with: "\n" + paragraphTag))
    }

    private static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    // MARK: 生成片段

    static func makeSnippet(_ text: String, tokens: [String]) -> Result? {
        let ns = text as NSString
        var best: NSRange?
        for t in tokens {
            let r = ns.range(of: t, options: NameMatcher.opts)
            if r.location != NSNotFound, best == nil || r.location < best!.location { best = r }
        }
        guard let hit = best else { return nil }
        let before = 28, after = 140
        var start = max(0, hit.location - before)
        let end = min(ns.length, hit.location + hit.length + after)
        // 尽量从句子开头开始
        let head = ns.substring(with: NSRange(location: start, length: hit.location - start))
        if let cut = head.lastIndex(where: { "。！？!?\n；;".contains($0) }) {
            start += (String(head[...cut]) as NSString).length
        }
        let safe = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var piece = ns.substring(with: safe)
        piece = piece.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if safe.location > 0 { piece = "…" + piece }
        if safe.location + safe.length < ns.length { piece += "…" }

        let ps = piece as NSString
        var ranges: [NSRange] = []
        for t in tokens {
            var search = NSRange(location: 0, length: ps.length)
            while search.length > 0 {
                let r = ps.range(of: t, options: NameMatcher.opts, range: search)
                if r.location == NSNotFound || r.length == 0 { break }
                ranges.append(r)
                let next = r.location + r.length
                search = NSRange(location: next, length: ps.length - next)
            }
        }
        return Result(text: piece, ranges: ranges)
    }
}
