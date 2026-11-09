import Foundation

/// 轻量 Markdown → HTML（AI 回答专用）：标题、段落、列表（可嵌套 / 任务列表）、引用、表格、代码块（带高亮）、
/// 分隔线、粗体、斜体、删除线、行内代码、链接、来源角标 [1]。流式输出时未闭合的代码块按代码块显示。
enum MarkdownRenderer {

    /// citations：来源列表，用于把 [1] 渲染成可点击的角标；为空时不处理角标
    static func html(_ md: String, citations: [WebResult] = []) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        var r = Renderer(lines: lines, citations: citations)
        return r.blocks(until: lines.count)
    }

    /// 转成适合粘贴到聊天框的纯文本：去掉 Markdown 标记与来源角标
    static func plainText(_ md: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { out.append(raw); continue }
            var line = raw
            if isHR(t) { out.append("———"); continue }
            if isTableSeparator(t) { continue }
            if t.range(of: "^#{1,6}\\s", options: .regularExpression) != nil {
                line = line.replacingOccurrences(of: "^\\s{0,3}#{1,6}\\s+", with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
            }
            line = line.replacingOccurrences(of: "^(\\s*)>\\s?", with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "^(\\s*)[-*+]\\s+\\[( |x|X)\\]\\s+", with: "$1• ", options: .regularExpression)
            line = line.replacingOccurrences(of: "^(\\s*)[-*+]\\s+", with: "$1• ", options: .regularExpression)
            line = stripInline(line)
            if t.hasPrefix("|") && t.hasSuffix("|") {
                line = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "\u{1}")
                line = String(line.dropFirst().dropLast()).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
                    .replacingOccurrences(of: "\u{1}", with: "|")
            }
            out.append(line)
        }
        var s = out.joined(separator: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInline(_ s: String) -> String {
        var l = s
        l = l.replacingOccurrences(of: "!?\\[([^\\]]+)\\]\\((\\S+?)\\)", with: "$1（$2）", options: .regularExpression)
        l = l.replacingOccurrences(of: citePattern, with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "(?<![\\*\\w])\\*(?!\\s)(.+?)(?<!\\s)\\*(?!\\*)", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "~~(.+?)~~", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        return l
    }

    // MARK: 共用判断

    static let citePattern = "\\s?(?:\\[\\d{1,2}(?:\\s*[,，、]\\s*\\d{1,2})*\\](?!\\()|【\\d{1,2}】)"

    static func isHR(_ t: String) -> Bool {
        t.range(of: "^(?:(?:\\*\\s*){3,}|(?:-\\s*){3,}|(?:_\\s*){3,})$", options: .regularExpression) != nil
    }
    static func isTableSeparator(_ t: String) -> Bool {
        t.contains("-") && t.range(of: "^\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?$", options: .regularExpression) != nil
    }
    static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, start: Int, content: String)? {
        guard let r = line.range(of: "^( *)([-*+]|\\d{1,3}[.)])\\s+", options: .regularExpression) else { return nil }
        let marker = String(line[r])
        let indent = marker.prefix { $0 == " " }.count
        let sym = marker.trimmingCharacters(in: .whitespaces)
        let ordered = sym.first?.isNumber == true
        let start = ordered ? Int(sym.dropLast()) ?? 1 : 1
        return (indent, ordered, start, String(line[r.upperBound...]))
    }

    static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default: o.append(c)
            }
        }
        return o
    }

    // MARK: - 块级

    private struct Renderer {
        let lines: [String]
        let citations: [WebResult]
        var i = 0

        init(lines: [String], citations: [WebResult]) {
            self.lines = lines
            self.citations = citations
        }

        func trimmed(_ k: Int) -> String { lines[k].trimmingCharacters(in: .whitespaces) }

        func fence(_ t: String) -> String? {
            if t.hasPrefix("```") { return "```" }
            if t.hasPrefix("~~~") { return "~~~" }
            return nil
        }

        func startsBlock(_ k: Int) -> Bool {
            let t = trimmed(k)
            if t.isEmpty || fence(t) != nil || t.hasPrefix(">") || isHR(t) { return true }
            if t.range(of: "^#{1,6}\\s", options: .regularExpression) != nil { return true }
            if listMarker(lines[k]) != nil { return true }
            if t.contains("|"), k + 1 < lines.count, isTableSeparator(trimmed(k + 1)) { return true }
            return false
        }

        mutating func blocks(until end: Int) -> String {
            var out = ""
            while i < end {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { i += 1; continue }

                if let f = fence(t) {
                    out += codeBlock(fence: f, end: end)
                    continue
                }
                if let m = t.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                    let level = t[m].filter { $0 == "#" }.count
                    var text = String(t[m.upperBound...])
                    text = text.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                    out += "<h\(level)>\(inline(text))</h\(level)>\n"
                    i += 1
                    continue
                }
                if isHR(t) { out += "<hr>\n"; i += 1; continue }
                if t.hasPrefix(">") {
                    var inner: [String] = []
                    while i < end, trimmed(i).hasPrefix(">") {
                        inner.append(trimmed(i).replacingOccurrences(of: "^>\\s?", with: "", options: .regularExpression))
                        i += 1
                    }
                    var sub = Renderer(lines: inner, citations: citations)
                    out += "<blockquote>\(sub.blocks(until: inner.count))</blockquote>\n"
                    continue
                }
                if t.contains("|"), i + 1 < end, isTableSeparator(trimmed(i + 1)) {
                    out += table(end: end)
                    continue
                }
                if listMarker(line) != nil {
                    out += list(end: end)
                    continue
                }
                // 段落：中文回答里换行通常就是想换行，保留为 <br>
                var parts: [String] = []
                while i < end, !trimmed(i).isEmpty, parts.isEmpty || !startsBlock(i) {
                    parts.append(inline(trimmed(i)))
                    i += 1
                }
                out += "<p>\(parts.joined(separator: "<br>"))</p>\n"
            }
            return out
        }

        mutating func codeBlock(fence f: String, end: Int) -> String {
            let open = lines[i]
            let indent = open.prefix { $0 == " " }.count
            let lang = open.trimmingCharacters(in: .whitespaces).dropFirst(3)
                .trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            i += 1
            var code: [String] = []
            var closed = false
            while i < end {
                if trimmed(i).hasPrefix(f) && trimmed(i).trimmingCharacters(in: CharacterSet(charactersIn: f.prefix(1) + " ")).isEmpty {
                    closed = true
                    i += 1
                    break
                }
                var l = lines[i]
                let strip = min(indent, l.prefix { $0 == " " }.count)
                l.removeFirst(strip)
                code.append(l)
                i += 1
            }
            return MarkdownRenderer.codeHTML(code.joined(separator: "\n"), lang: lang, closed: closed)
        }

        mutating func table(end: Int) -> String {
            func cells(_ s: String) -> [String] {
                var t = s.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("|") { t.removeFirst() }
                if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
                // 允许单元格里出现 \|
                let placeholder = "\u{1}"
                return t.replacingOccurrences(of: "\\|", with: placeholder).components(separatedBy: "|")
                    .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
            }
            let head = cells(lines[i])
            let aligns = cells(lines[i + 1]).map { c -> String in
                let l = c.hasPrefix(":"), r = c.hasSuffix(":")
                return l && r ? "center" : (r ? "right" : (l ? "left" : ""))
            }
            i += 2
            var html = "<div class=\"table-wrap\"><table><thead><tr>"
            for (k, h) in head.enumerated() {
                let a = k < aligns.count && !aligns[k].isEmpty ? " style=\"text-align:\(aligns[k])\"" : ""
                html += "<th\(a)>\(inline(h))</th>"
            }
            html += "</tr></thead><tbody>"
            while i < end, !trimmed(i).isEmpty, trimmed(i).contains("|") {
                let row = cells(lines[i])
                html += "<tr>"
                for k in 0..<head.count {
                    let a = k < aligns.count && !aligns[k].isEmpty ? " style=\"text-align:\(aligns[k])\"" : ""
                    html += "<td\(a)>\(k < row.count ? inline(row[k]) : "")</td>"
                }
                html += "</tr>"
                i += 1
            }
            return html + "</tbody></table></div>\n"
        }

        mutating func list(end: Int) -> String {
            var html = ""
            var stack: [(indent: Int, ordered: Bool)] = []
            func open(_ ordered: Bool, _ start: Int, _ indent: Int) {
                html += ordered ? (start != 1 ? "<ol start=\"\(start)\">" : "<ol>") : "<ul>"
                stack.append((indent, ordered))
            }
            func closeTop() {
                guard let top = stack.popLast() else { return }
                html += top.ordered ? "</li></ol>" : "</li></ul>"
            }

            while i < end {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if let m = listMarker(line) {
                    if stack.isEmpty || m.indent > stack.last!.indent + 1 {
                        open(m.ordered, m.start, m.indent)
                    } else {
                        while stack.count > 1, m.indent < stack.last!.indent - 1 { closeTop() }
                        if stack.last!.ordered != m.ordered {
                            closeTop()
                            open(m.ordered, m.start, m.indent)
                        } else {
                            html += "</li>"
                        }
                    }
                    var content = m.content
                    var cls = ""
                    if let tr = content.range(of: "^\\[( |x|X)\\]\\s+", options: .regularExpression) {
                        let done = content[tr].contains("x") || content[tr].contains("X")
                        content = String(content[tr.upperBound...])
                        cls = done ? " class=\"task done\"" : " class=\"task\""
                    }
                    html += "<li\(cls)>" + (cls.isEmpty ? "" : "<span class=\"box\"></span>") + inline(content)
                    i += 1
                    continue
                }
                if t.isEmpty {
                    // 空行后若还是列表项或缩进内容，列表继续
                    var k = i + 1
                    while k < end, trimmed(k).isEmpty { k += 1 }
                    if k < end, listMarker(lines[k]) != nil || lines[k].hasPrefix("  ") {
                        i = k
                        continue
                    }
                    break
                }
                let indented = line.hasPrefix("  ")
                if let f = fence(t), indented || !stack.isEmpty {
                    _ = f
                    html += codeBlock(fence: fence(t)!, end: end)
                    continue
                }
                if indented || (i > 0 && !trimmed(i - 1).isEmpty && !startsBlock(i)) {
                    if t.contains("|"), i + 1 < end, isTableSeparator(trimmed(i + 1)) {
                        html += table(end: end)
                    } else {
                        html += "<br>" + inline(t)
                        i += 1
                    }
                    continue
                }
                break
            }
            while !stack.isEmpty { closeTop() }
            return html + "\n"
        }

        // MARK: 行内

        func inline(_ s: String) -> String {
            var stash: [String] = []
            func keep(_ h: String) -> String {
                stash.append(h)
                return "\u{0}\(stash.count - 1)\u{0}"
            }
            var text = MarkdownRenderer.escape(s)

            // 行内代码
            text = replace(text, "(`+)(.+?)\\1") { g in keep("<code>\(g[2])</code>") }
            // 图片当链接显示（不加载外部图片）
            text = replace(text, "!\\[([^\\]]*)\\]\\((https?://[^\\s)]+)\\)") { g in
                keep("<a href=\"\(g[2])\">🖼 \(g[1].isEmpty ? "图片" : g[1])</a>")
            }
            // 链接
            text = replace(text, "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)") { g in
                keep("<a href=\"\(g[2])\">\(g[1])</a>")
            }
            // 来源角标
            if !citations.isEmpty {
                text = replace(text, MarkdownRenderer.citePattern) { g in
                    let nums = g[0].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                    let sups = nums.filter { $0 >= 1 && $0 <= citations.count }.map { n -> String in
                        "<sup class=\"cite\" data-cite=\"\(n)\">\(n)</sup>"
                    }
                    return sups.isEmpty ? "" : keep(sups.joined())
                }
            }
            // 自动链接
            text = replace(text, "(https?://[^\\s<\\u0000]+[^\\s<.,;:!?)\\]，。；：！？）、\\u0000])") { g in
                keep("<a href=\"\(g[1])\">\(g[1])</a>")
            }
            text = replace(text, "\\*\\*(.+?)\\*\\*") { g in "<strong>\(g[1])</strong>" }
            text = replace(text, "__(.+?)__") { g in "<strong>\(g[1])</strong>" }
            text = replace(text, "(?<![\\*\\w])\\*(?!\\s)(.+?)(?<!\\s)\\*(?!\\*)") { g in "<em>\(g[1])</em>" }
            text = replace(text, "~~(.+?)~~") { g in "<del>\(g[1])</del>" }

            // 还原占位（可能嵌套，最多展开几层）
            for _ in 0..<3 where text.contains("\u{0}") {
                text = replace(text, "\\u0000(\\d+)\\u0000") { g in
                    Int(g[1]).flatMap { $0 < stash.count ? stash[$0] : nil } ?? ""
                }
            }
            return text
        }

        private func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
            guard s.count > 1, let re = MarkdownRenderer.regex(pattern) else { return s }
            let ns = s as NSString
            let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return s }
            var out = ""
            var last = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                var groups: [String] = []
                for g in 0..<m.numberOfRanges {
                    let r = m.range(at: g)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
                out += f(groups)
                last = m.range.location + m.range.length
            }
            return out + ns.substring(from: last)
        }
    }

    // MARK: - 正则缓存

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()
    static func regex(_ p: String) -> NSRegularExpression? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = regexCache[p] { return r }
        let r = try? NSRegularExpression(pattern: p)
        regexCache[p] = r
        return r
    }

    // MARK: - 代码块

    static func codeHTML(_ code: String, lang: String, closed: Bool) -> String {
        let l = lang.lowercased()
        let label = l.isEmpty ? "代码" : lang
        let body = highlight(code, lang: l)
        return "<div class=\"code\(closed ? "" : " open")\"><div class=\"code-head\"><span>\(escape(label))</span>"
            + "<button class=\"copy-code\">复制</button></div><pre><code>\(body)</code></pre></div>\n"
    }

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "repeat", "return", "import", "class", "struct", "enum",
        "protocol", "extension", "guard", "switch", "case", "default", "break", "continue", "in", "async", "await",
        "try", "catch", "throw", "throws", "def", "lambda", "from", "as", "with", "pass", "yield", "function", "const",
        "new", "this", "self", "Self", "true", "false", "nil", "null", "None", "True", "False", "public", "private",
        "protected", "static", "final", "override", "void", "interface", "type", "export", "package", "go", "defer",
        "select", "where", "and", "or", "not", "is", "echo", "then", "fi", "do", "done", "esac", "elif", "local",
        "sudo", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER", "ON",
        "GROUP", "BY", "ORDER", "LIMIT", "CREATE", "TABLE", "AND", "OR", "NOT", "NULL", "AS", "INTO", "VALUES",
        "SET", "HAVING", "DISTINCT", "COUNT", "SUM", "AVG", "MAX", "MIN", "IF", "IFERROR", "VLOOKUP", "XLOOKUP",
        "INDEX", "MATCH", "SUMIFS", "COUNTIFS", "FILTER", "LET", "TEXT", "DATE", "TODAY", "fn", "mut", "impl", "pub",
        "use", "mod", "match", "int", "string", "bool", "float", "double", "char", "long", "unsigned", "auto",
        "typeof", "instanceof", "undefined", "of", "get", "some", "any", "inout", "init", "deinit", "weak", "lazy",
    ]
    private static let hashComment: Set<String> = ["sh", "bash", "zsh", "shell", "python", "py", "ruby", "rb", "yaml",
                                                   "yml", "toml", "perl", "r", "dockerfile", "makefile", "conf",
                                                   "ini", "powershell", "ps1", "fish", "console", "terminal"]
    private static let plainLangs: Set<String> = ["", "text", "plain", "plaintext", "txt", "markdown", "md", "output"]

    static func highlight(_ code: String, lang: String) -> String {
        guard !plainLangs.contains(lang), code.count < 60_000 else { return escape(code) }
        let comment = hashComment.contains(lang) ? "#[^\\n]*" : (lang == "sql" || lang == "lua" ? "--[^\\n]*" : "//[^\\n]*")
        let pattern = "(/\\*[\\s\\S]*?\\*/|\(comment))|(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)"
            + "|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_][A-Za-z0-9_]*)"
        guard let re = regex(pattern) else { return escape(code) }
        let ns = code as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            out += escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let tok = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                out += "<span class=\"hl-c\">\(escape(tok))</span>"
            } else if m.range(at: 2).location != NSNotFound {
                out += "<span class=\"hl-s\">\(escape(tok))</span>"
            } else if m.range(at: 3).location != NSNotFound {
                out += "<span class=\"hl-n\">\(tok)</span>"
            } else if keywords.contains(tok) {
                out += "<span class=\"hl-k\">\(tok)</span>"
            } else {
                out += escape(tok)
            }
            last = m.range.location + m.range.length
        }
        return out + escape(ns.substring(from: last))
    }
}
