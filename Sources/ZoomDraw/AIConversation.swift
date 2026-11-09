import AppKit

// MARK: - 数据

/// 一轮问答
struct AITurn: Codable {
    enum Phase: String, Codable { case searching, answering, done, stopped, failed }

    /// 显示的问题（AI 搜索 / 追问）
    var query: String
    /// AI 指令的输入内容（可能很长，显示时折叠）
    var input: String?
    /// 识图：剪贴板图片条目 id（用于显示缩略图、追问时重新读取图片）
    var imageClipID: UUID?
    var hasImage = false

    var searched = false
    var sources: [WebResult] = []
    var searchErrors: [String] = []
    var reasoning = ""
    var answer = ""
    var related: [String] = []
    var error: String?
    var isAuthError = false
    var phase: Phase = .answering
    var startedAt = Date()
    var searchTime: Double?
    var duration: Double?
    var model: String?

    /// 联网搜索失败，回答没有参考网页
    var offline: Bool { searched && sources.isEmpty }
    var isRunning: Bool { phase == .searching || phase == .answering }
}

/// 一次对话（保存在 AI 历史里）
struct AISessionRecord: Codable {
    var id = UUID()
    var engine: WebSearchEngine
    var turns: [AITurn]
    var createdAt = Date()
    var updatedAt = Date()

    var title: String {
        guard let t = turns.first else { return engine.name }
        if !t.query.isEmpty { return t.query }
        if let i = t.input { return i.split(whereSeparator: \.isNewline).first.map(String.init) ?? i }
        return t.hasImage ? "图片" : engine.name
    }
    /// 最后一个有内容的回答
    var lastAnswer: String { turns.last(where: { !$0.answer.isEmpty })?.answer ?? "" }
}

extension Notification.Name {
    static let aiHistoryChanged = Notification.Name("ZoomDraw.aiHistoryChanged")
}

// MARK: - 历史

final class AIHistoryStore {
    static let shared = AIHistoryStore()
    static let maxSessions = 300

    private(set) var sessions: [AISessionRecord] = []
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("ZoomDraw", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("AIHistory.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([AISessionRecord].self, from: data) {
            sessions = list.map { r in
                var r = r
                for i in r.turns.indices where r.turns[i].isRunning { r.turns[i].phase = .stopped }
                return r
            }
        }
    }

    func upsert(_ r: AISessionRecord) {
        guard AISettings.historyEnabled else { return }
        guard r.turns.contains(where: { !$0.answer.isEmpty }) else { return }
        sessions.removeAll { $0.id == r.id }
        sessions.insert(r, at: 0)
        if sessions.count > Self.maxSessions { sessions.removeLast(sessions.count - Self.maxSessions) }
        changed()
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        changed()
    }

    func clear() {
        sessions.removeAll()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .aiHistoryChanged, object: nil)
        saveWork?.cancel()
        let snapshot = sessions, url = fileURL
        let w = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func flush() {
        guard let w = saveWork else { return }
        saveWork = nil
        w.cancel()
        if let data = try? JSONEncoder().encode(sessions) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - 对话

/// 驱动一次对话：联网搜索 → 组织提示词 → 流式生成；支持追问、停止、重新生成
final class AIConversation {
    private(set) var record: AISessionRecord
    var engine: WebSearchEngine { record.engine }
    var turns: [AITurn] { record.turns }

    /// 某一轮有变化（-1 表示整体刷新）
    var onUpdate: ((Int) -> Void)?

    private var images: [Int: Data] = [:]
    private var searchTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var generation = 0
    private var rawAnswer = ""

    var isRunning: Bool { record.turns.last?.isRunning == true }

    init(engine: WebSearchEngine) {
        record = AISessionRecord(engine: engine, turns: [])
    }

    init(record: AISessionRecord) {
        self.record = record
    }

    // MARK: 开始 / 追问

    /// 第一轮：query 为问题（AI 搜索），input 为 AI 指令的输入；image 为识图的 JPEG
    func start(query: String, input: String?, image: Data?, imageClipID: UUID?) {
        var t = AITurn(query: query)
        t.input = input
        t.hasImage = image != nil
        t.imageClipID = imageClipID
        record.turns = [t]
        if let img = image { images[0] = img }
        run(0)
    }

    func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        stop()
        record.turns.append(AITurn(query: q))
        run(record.turns.count - 1)
    }

    func regenerate() {
        guard !record.turns.isEmpty else { return }
        stop()
        run(record.turns.count - 1)
    }

    func stop() {
        searchTask?.cancel(); searchTask = nil
        streamTask?.cancel(); streamTask = nil
        generation += 1
        let k = record.turns.count - 1
        guard k >= 0, record.turns[k].isRunning else { return }
        record.turns[k].phase = .stopped
        record.turns[k].duration = Date().timeIntervalSince(record.turns[k].startedAt)
        finish(k)
    }

    // MARK: 运行

    private func run(_ k: Int) {
        generation += 1
        let gen = generation
        var t = record.turns[k]
        t.sources = []; t.searchErrors = []; t.reasoning = ""; t.answer = ""; t.related = []
        t.error = nil; t.isAuthError = false; t.searchTime = nil; t.duration = nil
        t.startedAt = Date()
        let needSearch = engine.kind == .aiSearch && !isImageSession
        t.searched = needSearch
        t.phase = needSearch ? .searching : .answering
        record.turns[k] = t
        rawAnswer = ""
        onUpdate?(k)

        guard let cfg = AIClient.Config.current else {
            fail(k, AIError("还没有设置 AI 接口：请在「偏好设置 → AI」中填写接口地址、API Key 和模型", isAuth: true))
            return
        }
        record.turns[k].model = cfg.model

        if needSearch {
            let q = searchQuery(for: k)
            let sources = AISettings.sources.isEmpty ? [.sogou, .so360] : AISettings.sources
            let limit = AISettings.resultCount
            searchTask = Task { [weak self] in
                let t0 = Date()
                let (results, errors) = await WebSearcher.search(q, sources: sources, limit: limit)
                await MainActor.run { [weak self] in
                    guard let self = self, gen == self.generation else { return }
                    self.record.turns[k].sources = results
                    self.record.turns[k].searchErrors = errors
                    self.record.turns[k].searchTime = Date().timeIntervalSince(t0)
                    self.record.turns[k].phase = .answering
                    self.onUpdate?(k)
                    self.generate(k, cfg: cfg, gen: gen)
                }
            }
        } else {
            generate(k, cfg: cfg, gen: gen)
        }
    }

    private func generate(_ k: Int, cfg: AIClient.Config, gen: Int) {
        let msgs = messages(for: k)
        streamTask = AIClient.stream(msgs, config: cfg, onEvent: { [weak self] ev in
            guard let self = self, gen == self.generation else { return }
            switch ev {
            case .reasoning(let r):
                self.record.turns[k].reasoning += r
            case .content(let c):
                self.rawAnswer += c
                self.applyAnswer(k, streaming: true)
            }
            self.onUpdate?(k)
        }, completion: { [weak self] err in
            guard let self = self, gen == self.generation else { return }
            self.streamTask = nil
            if let err = err {
                if err is CancellationError { return }
                self.fail(k, err)
                return
            }
            self.applyAnswer(k, streaming: false)
            var t = self.record.turns[k]
            if t.answer.isEmpty && t.reasoning.isEmpty { t.error = "模型没有返回内容，请重试" }
            t.phase = t.error == nil ? .done : .failed
            t.duration = Date().timeIntervalSince(t.startedAt)
            self.record.turns[k] = t
            self.finish(k)
        })
    }

    private func fail(_ k: Int, _ err: Error) {
        var t = record.turns[k]
        t.error = AIClient.describe(err)
        t.isAuthError = (err as? AIError)?.isAuth == true
        t.phase = .failed
        t.duration = Date().timeIntervalSince(t.startedAt)
        record.turns[k] = t
        finish(k)
    }

    private func finish(_ k: Int) {
        record.updatedAt = Date()
        onUpdate?(k)
        AIHistoryStore.shared.upsert(record)
    }

    /// 把模型输出拆成「回答」和「相关问题」；流式时隐藏还没输出完整的 <related> 标签
    private func applyAnswer(_ k: Int, streaming: Bool) {
        var text = rawAnswer
        var related: [String] = []
        if let r = text.range(of: "<related>", options: .caseInsensitive) {
            var tail = String(text[r.upperBound...])
            if let e = tail.range(of: "</related>", options: .caseInsensitive) { tail = String(tail[..<e.lowerBound]) }
            text = String(text[..<r.lowerBound])
            related = tail.components(separatedBy: .newlines).map {
                $0.replacingOccurrences(of: "^\\s*(?:[-*•]|\\d+[.)、])\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty && !$0.hasPrefix("<") && $0.count <= 80 }
            // 流式输出时最后一行可能还没写完
            if streaming, rawAnswer.range(of: "</related>", options: .caseInsensitive) == nil,
               !rawAnswer.hasSuffix("\n"), !related.isEmpty {
                related.removeLast()
            }
        } else if streaming, let lt = text.lastIndex(of: "<") {
            let tail = text[lt...].lowercased()
            if "<related>".hasPrefix(tail) { text = String(text[..<lt]) }
        }
        record.turns[k].answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.turns[k].related = Array(related.prefix(4))
    }

    // MARK: 提示词

    private var isImageSession: Bool { record.turns.first?.hasImage == true }

    private func imageData() -> Data? {
        if let d = images[0] { return d }
        guard let id = record.turns.first?.imageClipID,
              let img = NSImage(contentsOf: ClipboardStore.shared.imageURL(id)),
              let d = AIClient.jpegData(img) else { return nil }
        images[0] = d
        return d
    }

    /// 追问很短时（“那价格呢”）带上第一轮的问题一起搜
    private func searchQuery(for k: Int) -> String {
        let q = record.turns[k].query
        var s = q
        if k > 0, q.count < 14, let first = record.turns.first?.query, !first.isEmpty { s = first + " " + q }
        return String(s.prefix(80))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return f
    }()

    private func systemPrompt() -> String {
        let now = Self.dateFormatter.string(from: Date())
        switch engine.kind {
        case .aiSearch:
            var s = """
            你是 ZoomDraw 的 AI 搜索助手。当前时间：\(now)。
            用户的问题后面会附上联网搜索结果（编号 [1]…[n]，只有标题和摘要）。请按以下要求回答：
            1. 使用与用户问题相同的语言（默认简体中文）。开头先用一两句话直接给出结论，再按需要分点展开。
            2. 依据搜索结果回答，在用到某条结果的句子末尾标注来源编号，如 [1] 或 [2][3]；不要编造编号，不要在文末另列参考资料。
            3. 搜索结果不相关或信息不足时，可以结合自己的知识回答，但要说明哪些内容没有得到搜索结果证实；价格、政策、版本等时效性信息提醒以官方最新信息为准。
            4. 善用 Markdown：小标题（###）、列表、加粗重点；对比类问题用表格；代码、命令放在代码块里。简洁清楚，不要客套话，不要复述问题。
            5. 回答的最后另起一行输出 <related>，接着写 3 个用户可能想继续追问的问题（每行一个，不加编号），然后输出 </related>。
            """
            let extra = engine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty { s += "\n6. 额外要求：\(extra)" }
            if record.turns.first?.hasImage == true {
                s += "\n（本次对话没有搜索结果，用户提供了一张图片，请根据图片内容回答，不要标注来源编号。）"
            }
            return s
        case .aiPrompt, .web:
            return """
            你是 ZoomDraw 内置的 AI 助手。当前时间：\(now)。
            直接给出用户要的结果，不要客套话和多余的开场白；需要时使用 Markdown（列表、表格、代码块）让结果清晰易读。
            """
        }
    }

    private func messages(for k: Int) -> [AIMessage] {
        var msgs = [AIMessage(role: "system", text: systemPrompt())]
        for i in 0...k {
            let t = record.turns[i]
            var m = AIMessage(role: "user", text: userText(i, current: i == k))
            if i == 0, t.hasImage { m.image = imageData() }
            msgs.append(m)
            if i < k, !t.answer.isEmpty { msgs.append(AIMessage(role: "assistant", text: t.answer)) }
        }
        return msgs
    }

    private func userText(_ i: Int, current: Bool) -> String {
        let t = record.turns[i]
        if i == 0, engine.kind == .aiPrompt {
            let input = t.input ?? t.query
            let p = engine.prompt
            if p.contains(WebSearchEngine.placeholder) {
                return p.replacingOccurrences(of: WebSearchEngine.placeholder,
                                              with: input.isEmpty && t.hasImage ? "（见图片）" : input)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return p + "\n\n" + input
        }
        if i == 0, t.hasImage {
            return t.query.isEmpty ? "请识别这张图片：说明图片内容；如果有文字请提取出来；如果图片里是一道题或一个问题，请直接解答。"
                                   : t.query
        }
        guard engine.kind == .aiSearch, current, t.searched else { return t.query }
        if t.sources.isEmpty {
            return "问题：\(t.query)\n\n（联网搜索失败，没有搜索结果。请根据你自己的知识回答，并在开头提醒用户：未联网，内容可能过时。不要标注来源编号。）"
        }
        var s = "问题：\(t.query)\n\n搜索结果：\n"
        for (n, r) in t.sources.enumerated() {
            s += "[\(n + 1)] \(r.title)（\(r.host)）\n\(r.snippet)\n\n"
        }
        return s
    }
}
