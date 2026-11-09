import Foundation

/// 一条网页搜索结果
struct WebResult: Codable, Equatable {
    var title: String
    var url: String
    var snippet: String
    var source: String

    var host: String {
        guard let h = URL(string: url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// 免费联网搜索：直接读取搜狗 / 360 / DuckDuckGo 的结果页并解析（不是官方接口，改版时可能失效，多个来源互为备用）
/// 注：必应会对脚本请求返回随机无关结果，百度会跳人机验证，所以都不用
enum WebSearcher {
    enum Source: String, CaseIterable, Codable {
        case sogou, so360, duckduckgo
        var title: String {
            switch self {
            case .sogou: return "搜狗"
            case .so360: return "360 搜索"
            case .duckduckgo: return "DuckDuckGo"
            }
        }
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6",
                                   "Accept": "text/html,application/xhtml+xml"]
        return URLSession(configuration: c)
    }()

    /// 同时搜索多个来源，交错合并、去重；errors 为失败来源的说明
    static func search(_ query: String, sources: [Source], limit: Int) async -> (results: [WebResult], errors: [String]) {
        let lists = await withTaskGroup(of: (Source, Result<[WebResult], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s, .success(try await fetch(query, source: s))) } catch { return (s, .failure(error)) }
                }
            }
            var out: [Source: Result<[WebResult], Error>] = [:]
            for await (s, r) in group { out[s] = r }
            return out
        }
        var errors: [String] = []
        var ordered: [[WebResult]] = []
        for s in sources {
            switch lists[s] {
            case .success(let list)?:
                if list.isEmpty { errors.append("\(s.title)：没有解析到结果") } else { ordered.append(list) }
            case .failure(let e)?:
                errors.append("\(s.title)：\((e as? LocalizedError)?.errorDescription ?? e.localizedDescription)")
            case nil: break
            }
        }
        var seen = Set<String>()
        var merged: [WebResult] = []
        let maxLen = ordered.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for list in ordered where i < list.count {
                let key = dedupeKey(list[i].url)
                guard !seen.contains(key), isUseful(list[i]) else { continue }
                seen.insert(key)
                merged.append(list[i])
            }
        }
        return (Array(merged.prefix(limit)), errors)
    }

    struct SearchError: LocalizedError {
        let errorDescription: String?
    }

    static func fetch(_ query: String, source: Source) async throws -> [WebResult] {
        var comps: URLComponents
        switch source {
        case .sogou:
            comps = URLComponents(string: "https://www.sogou.com/web")!
            comps.queryItems = [.init(name: "query", value: query)]
        case .so360:
            comps = URLComponents(string: "https://www.so.com/s")!
            comps.queryItems = [.init(name: "q", value: query)]
        case .duckduckgo:
            comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
            comps.queryItems = [.init(name: "q", value: query), .init(name: "kl", value: "cn-zh")]
        }
        guard let url = comps.url else { throw SearchError(errorDescription: "关键字无效") }
        let (data, resp) = try await session.data(from: url)
        let final = resp.url?.absoluteString ?? ""
        if final.contains("antispider") || final.contains("captcha") {
            throw SearchError(errorDescription: "触发了人机验证，稍后再试")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 202 || code == 429 { throw SearchError(errorDescription: "请求太频繁，被暂时限流") }
        guard code == 200 else { throw SearchError(errorDescription: "HTTP \(code)") }
        let html = String(decoding: data, as: UTF8.self)
        switch source {
        case .sogou: return parseSogou(html)
        case .so360: return parse360(html)
        case .duckduckgo: return parseDuckDuckGo(html)
        }
    }

    // MARK: 解析

    static func parse360(_ html: String) -> [WebResult] {
        var out: [WebResult] = []
        for raw in html.components(separatedBy: "<li class=\"res-list").dropFirst() {
            var block = String(raw.prefix(8000))
            if let end = block.range(of: "</li>") { block = String(block[..<end.lowerBound]) }
            guard let (title, href, afterTitle) = titleLink(in: block, tag: "h3"),
                  title != "其他人还搜了" else { continue }
            // 360 的链接是跳转地址，真实网址在 data-mdurl
            var url = href
            if let m = block.range(of: "data-mdurl=\"([^\"]+)\"", options: .regularExpression) {
                url = decodeEntities(String(String(block[m]).dropFirst(12).dropLast()))
            }
            guard url.hasPrefix("http") else { continue }
            var snippet = ""
            if let s = afterTitle.range(of: "res-list-summary") {
                let rest = afterTitle[s.upperBound...]
                let start = rest.range(of: ">")?.upperBound ?? rest.startIndex
                let end = rest.range(of: "</span>")?.lowerBound ?? rest.endIndex
                if start < end { snippet = text(String(rest[start..<end])) }
            }
            if snippet.isEmpty { snippet = text(afterTitle) }
            for junk in ["反馈", "快照"] { snippet = snippet.replacingOccurrences(of: junk, with: "") }
            out.append(WebResult(title: title, url: url, snippet: clip(snippet, 300), source: "360"))
        }
        return out
    }

    static func parseDuckDuckGo(_ html: String) -> [WebResult] {
        var out: [WebResult] = []
        for raw in html.components(separatedBy: "class=\"result__a\"").dropFirst() {
            let block = String(raw.prefix(6000))
            guard let m = block.range(of: "href=\"([^\"]+)\"", options: .regularExpression),
                  let close = block.range(of: ">"), let endA = block.range(of: "</a>") else { continue }
            var href = decodeEntities(String(String(block[m]).dropFirst(6).dropLast()))
            // 跳转地址 //duckduckgo.com/l/?uddg=<真实网址>
            if href.hasPrefix("//") { href = "https:" + href }
            if let c = URLComponents(string: href), let u = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = u
            }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js"), close.upperBound <= endA.lowerBound
            else { continue }
            let title = text(String(block[close.upperBound..<endA.lowerBound]))
            var snippet = ""
            if let s = block.range(of: "class=\"result__snippet\"") {
                let rest = block[s.upperBound...]
                let start = rest.range(of: ">")?.upperBound ?? rest.startIndex
                let end = rest.range(of: "</a>")?.lowerBound ?? rest.endIndex
                if start < end { snippet = text(String(rest[start..<end])) }
            }
            guard !title.isEmpty else { continue }
            out.append(WebResult(title: title, url: href, snippet: clip(snippet, 300), source: "DuckDuckGo"))
        }
        return out
    }

    static func parseSogou(_ html: String) -> [WebResult] {
        var out: [WebResult] = []
        var body = html
        // 去掉页面底部的「相关搜索」等
        if let end = body.range(of: "id=\"hint_container\"") { body = String(body[..<end.lowerBound]) }
        let pattern = "<div class=\"(?:vrwrap|rb)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let starts = re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        for (i, s) in starts.enumerated() {
            let e = i + 1 < starts.count ? starts[i + 1] : min(ns.length, s + 8000)
            let block = ns.substring(with: NSRange(location: s, length: min(e - s, 8000)))
            guard let (title, href, afterTitle) = titleLink(in: block, tag: "h3") else { continue }
            var url = href
            if url.hasPrefix("/") { url = "https://www.sogou.com" + url }
            // 标题链接是搜狗的跳转地址，真实网址在 data-url 里
            if url.contains("sogou.com/link"),
               let m = block.range(of: "data-url=\"(https?://[^\"]+)\"", options: .regularExpression) {
                let real = decodeEntities(String(block[m].dropFirst(10).dropLast()))
                if URL(string: real)?.host != nil { url = real }
            }
            guard url.hasPrefix("http") else { continue }
            var snippet = text(afterTitle)
            for junk in ["快照", "翻译此页", "- 搜狗百科"] { snippet = snippet.replacingOccurrences(of: junk, with: "") }
            out.append(WebResult(title: title, url: url, snippet: clip(snippet, 300), source: "搜狗"))
        }
        return out
    }

    /// 找到 <h2>/<h3> 里的第一个链接，返回 标题、链接、标题之后的 HTML
    private static func titleLink(in block: String, tag: String) -> (String, String, String)? {
        guard let h = block.range(of: "<\(tag)"),
              let hEnd = block.range(of: "</\(tag)>", range: h.upperBound..<block.endIndex) else { return nil }
        let head = String(block[h.lowerBound..<hEnd.lowerBound])
        guard let m = head.range(of: "href=\"([^\"]+)\"", options: .regularExpression) else { return nil }
        var href = String(head[m]).dropFirst(6).dropLast()
        href = Substring(decodeEntities(String(href)))
        let title = text(head)
        guard !title.isEmpty else { return nil }
        return (title, String(href), String(block[hEnd.upperBound...]))
    }

    private static func dedupeKey(_ url: String) -> String {
        guard let u = URL(string: url), let h = u.host else { return url }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        // 跳转链接（sogou.com/link?url=…）路径都一样，用完整地址去重
        if u.path.hasSuffix("/link") || host.hasSuffix("sogou.com") { return url }
        return host + u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: 文本处理

    /// HTML → 纯文本：去掉脚本 / 样式 / 注释 / 标签，解码实体，合并空白
    static func text(_ html: String) -> String {
        var s = html
        for p in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        // 关键字高亮等行内标签直接去掉（否则「深圳<em>天气</em>」会变成「深圳 天气」），其他标签换成空格
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</?(?:em|b|strong|i|font|span|a|mark)\\b[^>]*>", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        // 偶尔混进来的内联样式
        s = s.replacingOccurrences(of: "[#.][\\w-]+\\s*\\{[^}]*\\}", with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 图片 / 视频 / 文库聚合页对回答没有帮助
    private static let junkHosts = ["image.so.com", "360kan.com", "video.so.com", "wenku.so.com", "pic.sogou.com",
                                    "v.sogou.com", "video.sogou.com"]
    static func isUseful(_ r: WebResult) -> Bool {
        let h = r.host
        if junkHosts.contains(where: { h.hasSuffix($0) }) { return false }
        if r.title.hasSuffix("图片") || r.title.contains("短视频") { return false }
        return true
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                       "&ensp;": " ", "&emsp;": " ", "&middot;": "·", "&hellip;": "…", "&mdash;": "—", "&ldquo;": "“",
                       "&rdquo;": "”"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                if let n = num, let sc = Unicode.Scalar(n) { result.unicodeScalars.append(sc) }
                else { result += ns.substring(with: m.range) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}
