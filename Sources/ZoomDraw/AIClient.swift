import AppKit
import Security

// MARK: - 设置

/// AI 接口设置（OpenAI 兼容）。API Key 存在系统钥匙串，不写入偏好设置文件
enum AISettings {
    private static let d = UserDefaults.standard

    enum Thinking: String, CaseIterable {
        /// 关闭思考：首字约 1 秒
        case fast
        /// 开启深度思考：更严谨，慢几秒
        case deep
        /// 不发送思考参数，由模型决定（兼容其他服务）
        case auto
        var title: String {
            switch self {
            case .fast: return "快速（关闭思考）"
            case .deep: return "深度（先思考再回答）"
            case .auto: return "由模型决定（不发送思考参数）"
            }
        }
    }

    static func registerDefaults() {
        d.register(defaults: [
            "ai.endpoint": "",
            "ai.model": "",
            "ai.thinking": Thinking.fast.rawValue,
            "ai.sources": WebSearcher.Source.allCases.map(\.rawValue),
            "ai.resultCount": 8,
            "ai.historyEnabled": true,
            "ai.temperature": 0.5,
        ])
    }

    static var endpoint: String {
        get { d.string(forKey: "ai.endpoint") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.endpoint"); changed() }
    }
    static var model: String {
        get { d.string(forKey: "ai.model") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model"); changed() }
    }
    static var thinking: Thinking {
        get { Thinking(rawValue: d.string(forKey: "ai.thinking") ?? "") ?? .fast }
        set { d.set(newValue.rawValue, forKey: "ai.thinking") }
    }
    static var sources: [WebSearcher.Source] {
        get { (d.stringArray(forKey: "ai.sources") ?? []).compactMap(WebSearcher.Source.init(rawValue:)) }
        set { d.set(newValue.map(\.rawValue), forKey: "ai.sources") }
    }
    static var resultCount: Int {
        get { min(12, max(3, d.integer(forKey: "ai.resultCount"))) }
        set { d.set(newValue, forKey: "ai.resultCount") }
    }
    static var historyEnabled: Bool {
        get { d.bool(forKey: "ai.historyEnabled") }
        set { d.set(newValue, forKey: "ai.historyEnabled") }
    }

    // MARK: Key（钥匙串）
    private static let service = "com.zoomdraw.app.ai"
    private static let account = "api-key"
    private static var cachedKey: String?

    static var apiKey: String {
        get {
            if let k = cachedKey { return k }
            var q = baseQuery
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let k = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
                ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
            cachedKey = k
            return k
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            SecItemDelete(baseQuery as CFDictionary)
            if !v.isEmpty {
                var q = baseQuery
                q[kSecValueData as String] = Data(v.utf8)
                q[kSecAttrLabel as String] = "ZoomDraw AI API Key"
                q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(q as CFDictionary, nil)
            }
            cachedKey = v
            changed()
        }
    }
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var isConfigured: Bool { chatURL != nil && !model.isEmpty && !apiKey.isEmpty }

    /// 接口地址可以填 …/v1 或完整的 …/v1/chat/completions
    static var chatURL: URL? { chatURL(from: endpoint) }
    static func chatURL(from s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard t.hasPrefix("http") else { return nil }
        if !t.hasSuffix("/chat/completions") { t += "/chat/completions" }
        return URL(string: t)
    }
    static func modelsURL(from s: String) -> URL? {
        guard let chat = chatURL(from: s)?.absoluteString else { return nil }
        return URL(string: String(chat.dropLast("/chat/completions".count)) + "/models")
    }

    private static func changed() { NotificationCenter.default.post(name: .aiSettingsChanged, object: nil) }

    /// 从 curl 命令中提取 接口地址 / Key / 模型
    static func parseCurl(_ s: String) -> (endpoint: String?, key: String?, model: String?) {
        let flat = s.replacingOccurrences(of: "\\\n", with: " ")
        func first(_ p: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)),
                  let r = Range(m.range(at: 1), in: flat) else { return nil }
            return String(flat[r])
        }
        var ep = first("(https?://[^\\s'\"]+)")
        if let e = ep, e.hasSuffix("/chat/completions") { ep = String(e.dropLast("/chat/completions".count)) }
        return (ep, first("Bearer\\s+([A-Za-z0-9._\\-]+)"), first("\"model\"\\s*:\\s*\"([^\"]+)\""))
    }
}

extension Notification.Name {
    static let aiSettingsChanged = Notification.Name("ZoomDraw.aiSettingsChanged")
}

// MARK: - 客户端

struct AIMessage: Codable, Equatable {
    var role: String
    var text: String
    /// JPEG 图片（只用于本次请求，历史里不保存图片数据）
    var image: Data?

    enum CodingKeys: String, CodingKey { case role, text }
}

struct AIError: LocalizedError {
    let errorDescription: String?
    var isAuth = false
    init(_ s: String, isAuth: Bool = false) { errorDescription = s; self.isAuth = isAuth }
}

/// OpenAI 兼容的流式对话接口
final class AIClient {
    enum Event { case reasoning(String), content(String) }

    struct Config {
        var url: URL
        var key: String
        var model: String
        var thinking: AISettings.Thinking
        var temperature: Double?

        static var current: Config? {
            guard let u = AISettings.chatURL, !AISettings.model.isEmpty, !AISettings.apiKey.isEmpty else { return nil }
            return Config(url: u, key: AISettings.apiKey, model: AISettings.model, thinking: AISettings.thinking,
                          temperature: 0.5)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// 开始流式请求；事件和结束回调都在主线程。返回的 Task 可以取消
    @discardableResult
    static func stream(_ messages: [AIMessage], config: Config,
                       onEvent: @escaping (Event) -> Void,
                       completion: @escaping (Error?) -> Void) -> Task<Void, Never> {
        Task {
            do {
                do {
                    try await run(messages, config: config, sendThinking: true, onEvent: onEvent)
                } catch let e as AIError where config.thinking != .auto && isThinkingParamError(e) {
                    // 有的服务不认识思考参数，去掉再试一次
                    try await run(messages, config: config, sendThinking: false, onEvent: onEvent)
                }
                await MainActor.run { completion(nil) }
            } catch is CancellationError {
                await MainActor.run { completion(CancellationError()) }
            } catch let e as URLError where e.code == .cancelled {
                await MainActor.run { completion(CancellationError()) }
            } catch {
                await MainActor.run { completion(error) }
            }
        }
    }

    private static func isThinkingParamError(_ e: AIError) -> Bool {
        let s = (e.errorDescription ?? "").lowercased()
        return s.contains("reasoning") || s.contains("unrecognized") || s.contains("unknown parameter")
    }

    private static func run(_ messages: [AIMessage], config: Config, sendThinking: Bool,
                            onEvent: @escaping (Event) -> Void) async throws {
        var req = URLRequest(url: config.url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(messages, config: config, sendThinking: sendThinking))

        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 65536 { break } }
            throw error(status: code, data: data)
        }

        // 合并小片段，约每 40ms 推送一次，避免界面频繁刷新
        var pendingContent = "", pendingReasoning = ""
        var lastFlush = Date()
        func flush() {
            let c = pendingContent, r = pendingReasoning
            pendingContent = ""; pendingReasoning = ""
            lastFlush = Date()
            guard !c.isEmpty || !r.isEmpty else { return }
            DispatchQueue.main.async {
                if !r.isEmpty { onEvent(.reasoning(r)) }
                if !c.isEmpty { onEvent(.content(c)) }
            }
        }

        var sawData = false
        var nonSSE = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else {
                if !sawData && nonSSE.count < 65536 { nonSSE += line + "\n" }
                continue
            }
            sawData = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw AIError(err["message"] as? String ?? "接口返回错误")
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                pendingReasoning += r
            }
            if let c = delta["content"] as? String, !c.isEmpty { pendingContent += c }
            if Date().timeIntervalSince(lastFlush) > 0.04 { flush() }
        }
        flush()

        // 服务没有按流式返回：按普通 JSON 解析
        if !sawData {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(nonSSE.utf8)) as? [String: Any] else {
                throw AIError("接口返回的内容无法识别")
            }
            if let err = obj["error"] as? [String: Any] { throw AIError(err["message"] as? String ?? "接口返回错误") }
            let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
            let r = (msg["reasoning_content"] as? String) ?? "", c = (msg["content"] as? String) ?? ""
            DispatchQueue.main.async {
                if !r.isEmpty { onEvent(.reasoning(r)) }
                if !c.isEmpty { onEvent(.content(c)) }
            }
        }
    }

    private static func body(_ messages: [AIMessage], config: Config, sendThinking: Bool) -> [String: Any] {
        var b: [String: Any] = ["model": config.model, "stream": true]
        if let t = config.temperature { b["temperature"] = t }
        if sendThinking {
            switch config.thinking {
            case .fast: b["reasoning_effort"] = "no_think"
            case .deep: b["reasoning_effort"] = "high"
            case .auto: break
            }
        }
        b["messages"] = messages.map { m -> [String: Any] in
            guard let img = m.image else { return ["role": m.role, "content": m.text] }
            return ["role": m.role, "content": [
                ["type": "text", "text": m.text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]],
            ]]
        }
        return b
    }

    private static func error(status: Int, data: Data) -> AIError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = ((obj?["error"] as? [String: Any])?["message"] as? String)
            ?? (obj?["message"] as? String)
            ?? String(data: data.prefix(300), encoding: .utf8)
        switch status {
        case 401: return AIError("API Key 无效或已过期（\(msg ?? "401")）", isAuth: true)
        case 403: return AIError("没有权限：\(msg ?? "403")", isAuth: true)
        case 404: return AIError("接口地址不正确（404），请检查是否以 /v1 结尾")
        case 429: return AIError("请求太频繁或额度已用完（429）：\(msg ?? "")")
        default: return AIError("接口返回 HTTP \(status)：\(msg ?? "")")
        }
    }

    /// 把网络错误转成看得懂的中文说明
    static func describe(_ err: Error) -> String {
        if let e = err as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "网络未连接"
            case .timedOut: return "请求超时，请稍后重试"
            case .cannotFindHost, .dnsLookupFailed:
                return "找不到 AI 接口的服务器（\(e.failingURL?.host ?? "")）。如果是公司内网接口，请确认已连接内网"
            case .cannotConnectToHost, .networkConnectionLost:
                return "无法连接到 AI 接口（\(e.localizedDescription)）"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "无法与 AI 接口建立安全连接（\(e.code.rawValue)）。如果是公司内网接口，可能是终端安全软件（如 iOA）"
                    + "没有放行 ZoomDraw 访问内网，请联系 IT 处理，或改用其他接口"
            default: return e.localizedDescription
            }
        }
        return (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
    }

    // MARK: 模型列表 / 测试连接

    static func fetchModels(endpoint: String, key: String) async throws -> [String] {
        guard let url = AISettings.modelsURL(from: endpoint) else { throw AIError("接口地址不正确") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw error(status: code, data: data) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    /// 发一句很短的话，返回耗时
    static func test(endpoint: String, key: String, model: String, thinking: AISettings.Thinking) async throws -> (String, TimeInterval) {
        guard let url = AISettings.chatURL(from: endpoint) else { throw AIError("接口地址不正确") }
        let cfg = Config(url: url, key: key, model: model, thinking: thinking, temperature: nil)
        let t0 = Date()
        var text = ""
        try await run([AIMessage(role: "user", text: "只回复两个字：你好")], config: cfg, sendThinking: thinking != .auto) {
            if case .content(let c) = $0 { text += c }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        return (text, Date().timeIntervalSince(t0))
    }

    // MARK: 图片

    /// 缩小到最长边 1600，转成 JPEG
    static func jpegData(_ image: NSImage, maxSide: CGFloat = 1600) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let s = min(1, maxSide / max(w, h))
        let tw = Int(w * s), th = Int(h * s)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
