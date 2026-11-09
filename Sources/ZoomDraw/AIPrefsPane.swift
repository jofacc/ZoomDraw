import AppKit

/// 偏好设置 →「AI」：接口、Key（钥匙串）、模型、思考模式、联网搜索来源、历史
final class AIPrefsPane: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    private let endpointField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyPlainField = NSTextField()
    private let showKeyButton = NSButton(checkboxWithTitle: "显示", target: nil, action: nil)
    private let modelBox = NSComboBox()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let thinkingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sourceChecks: [WebSearcher.Source: NSButton] = [:]
    private let countPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let historyCheck = NSButton(checkboxWithTitle: "保存 AI 历史（在剪贴板面板的「✦ AI 历史」中查看、继续追问）",
                                        target: nil, action: nil)
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 构建
    private func build() {
        let W = bounds.width, H = bounds.height
        let pad: CGFloat = 16, labelW: CGFloat = 70
        let fieldX = pad + labelW + 8, fieldW = W - fieldX - pad
        var y = H - 46

        let hint = NSTextField(wrappingLabelWithString:
            "AI 搜索和 AI 指令使用 OpenAI 兼容接口（混元、DeepSeek、通义千问、Kimi、OpenAI 等均可）。"
            + "API Key 保存在系统钥匙串中，不会写入配置文件。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 32)
        addSubview(hint)

        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.frame = NSRect(x: pad, y: y + 3, width: labelW, height: 17)
            addSubview(l)
        }
        func small(_ b: NSButton, _ action: Selector) -> NSButton {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            b.target = self
            b.action = action
            b.sizeToFit()
            b.frame.size.width += 8
            return b
        }

        // 接口地址
        y -= 34
        label("接口地址", y)
        endpointField.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 22)
        endpointField.placeholderString = "https://api.example.com/v1"
        endpointField.stringValue = AISettings.endpoint
        endpointField.delegate = self
        addSubview(endpointField)

        // Key
        y -= 32
        label("API Key", y)
        let keyW = fieldW - 58
        for f in [keyField, keyPlainField] as [NSTextField] {
            f.frame = NSRect(x: fieldX, y: y, width: keyW, height: 22)
            f.placeholderString = "sk-…"
            f.delegate = self
            addSubview(f)
        }
        keyField.stringValue = AISettings.apiKey
        keyPlainField.stringValue = keyField.stringValue
        keyPlainField.isHidden = true
        keyPlainField.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        showKeyButton.target = self
        showKeyButton.action = #selector(toggleShowKey)
        showKeyButton.frame = NSRect(x: fieldX + keyW + 8, y: y + 2, width: 52, height: 18)
        addSubview(showKeyButton)

        // 模型
        y -= 32
        label("模型", y)
        let fetch = small(NSButton(title: "获取模型列表", target: nil, action: nil), #selector(fetchModels))
        modelBox.frame = NSRect(x: fieldX, y: y - 1, width: fieldW - fetch.frame.width - 8, height: 24)
        modelBox.placeholderString = "例如 hy4、deepseek-chat、gpt-4o-mini"
        modelBox.stringValue = AISettings.model
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 12
        modelBox.delegate = self
        addSubview(modelBox)
        fetch.frame.origin = NSPoint(x: W - pad - fetch.frame.width, y: y)
        addSubview(fetch)

        // 导入 / 测试
        y -= 34
        let curl = small(NSButton(title: "从 curl 命令导入…", target: nil, action: nil), #selector(importCurl))
        curl.frame.origin = NSPoint(x: fieldX, y: y)
        addSubview(curl)
        let test = small(NSButton(title: "测试连接", target: nil, action: nil), #selector(testConnection))
        test.frame.origin = NSPoint(x: curl.frame.maxX + 6, y: y)
        addSubview(test)

        y -= 36
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 30)
        addSubview(status)
        updateStatus()

        y -= 10
        let sep = NSBox(frame: NSRect(x: pad, y: y, width: W - pad * 2, height: 1))
        sep.boxType = .separator
        addSubview(sep)

        // 思考
        y -= 36
        label("思考模式", y)
        for t in AISettings.Thinking.allCases {
            thinkingPopup.addItem(withTitle: t.title)
            thinkingPopup.lastItem?.representedObject = t.rawValue
            if t == AISettings.thinking { thinkingPopup.select(thinkingPopup.lastItem) }
        }
        thinkingPopup.frame = NSRect(x: fieldX - 3, y: y - 2, width: 250, height: 26)
        thinkingPopup.target = self
        thinkingPopup.action = #selector(thinkingChanged)
        addSubview(thinkingPopup)

        // 搜索来源
        y -= 32
        label("联网搜索", y)
        var x = fieldX
        let current = Set(AISettings.sources)
        for s in WebSearcher.Source.allCases {
            let b = NSButton(checkboxWithTitle: s.title, target: self, action: #selector(sourcesChanged))
            b.state = current.contains(s) ? .on : .off
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: y + 1)
            addSubview(b)
            sourceChecks[s] = b
            x = b.frame.maxX + 14
        }
        let srcNote = NSTextField(labelWithString: "AI 搜索只读取搜索结果的标题和摘要，不打开网页。DuckDuckGo 英文和技术类结果较好，但偶尔会限流。")
        srcNote.font = NSFont.systemFont(ofSize: 11)
        srcNote.textColor = .secondaryLabelColor
        srcNote.lineBreakMode = .byTruncatingTail
        srcNote.toolTip = srcNote.stringValue
        srcNote.frame = NSRect(x: fieldX, y: y - 18, width: fieldW, height: 15)
        addSubview(srcNote)

        // 条数
        y -= 50
        label("参考网页", y)
        for n in [3, 5, 8, 10, 12] {
            countPopup.addItem(withTitle: "最多 \(n) 条")
            countPopup.lastItem?.tag = n
        }
        countPopup.selectItem(withTag: AISettings.resultCount)
        if countPopup.selectedItem == nil { countPopup.selectItem(withTag: 8) }
        countPopup.frame = NSRect(x: fieldX - 3, y: y - 2, width: 120, height: 26)
        countPopup.target = self
        countPopup.action = #selector(countChanged)
        addSubview(countPopup)

        // 历史
        y -= 36
        historyCheck.state = AISettings.historyEnabled ? .on : .off
        historyCheck.target = self
        historyCheck.action = #selector(historyChanged)
        historyCheck.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 18)
        historyCheck.lineBreakMode = .byTruncatingTail
        addSubview(historyCheck)
        y -= 30
        let clear = small(NSButton(title: "清空 AI 历史…", target: nil, action: nil), #selector(clearHistory))
        clear.frame.origin = NSPoint(x: fieldX, y: y)
        addSubview(clear)

        let usage = NSTextField(wrappingLabelWithString:
            "用法：在剪贴板面板（输入框）里输入问题，按 ⌘1 进行 AI 搜索；输入框为空时处理选中的条目，选中图片可识别图片。"
            + "⌘1–9 对应的 AI 指令可在「快捷搜索」页调整。")
        usage.font = NSFont.systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor
        usage.frame = NSRect(x: pad, y: 12, width: W - pad * 2, height: 30)
        addSubview(usage)
    }

    // MARK: 保存

    private var keyValue: String {
        (showKeyButton.state == .on ? keyPlainField : keyField).stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveFields() {
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ep != AISettings.endpoint { AISettings.endpoint = ep }
        let m = modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if m != AISettings.model { AISettings.model = m }
        let k = keyValue
        if k != AISettings.apiKey { AISettings.apiKey = k }
        updateStatus()
    }

    func controlTextDidEndEditing(_ obj: Notification) { saveFields() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.saveFields() }
    }

    private func updateStatus() {
        guard !busy else { return }
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespaces)
        if !ep.isEmpty && AISettings.chatURL(from: ep) == nil {
            setStatus("⚠️ 接口地址需以 http:// 或 https:// 开头", .systemOrange)
        } else if ep.isEmpty || keyValue.isEmpty || modelBox.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            setStatus("填写接口地址、API Key 和模型后即可使用；也可以直接粘贴服务商文档里的 curl 示例导入。", .secondaryLabelColor)
        } else {
            setStatus("已设置。请求地址：\(AISettings.chatURL(from: ep)?.absoluteString ?? "")", .secondaryLabelColor)
        }
    }

    private func setStatus(_ s: String, _ c: NSColor) {
        status.stringValue = s
        status.textColor = c
    }

    // MARK: 动作

    @objc private func toggleShowKey() {
        let show = showKeyButton.state == .on
        if show { keyPlainField.stringValue = keyField.stringValue } else { keyField.stringValue = keyPlainField.stringValue }
        keyPlainField.isHidden = !show
        keyField.isHidden = show
    }

    @objc private func fetchModels() {
        saveFields()
        let ep = AISettings.endpoint, key = AISettings.apiKey
        guard AISettings.chatURL(from: ep) != nil, !key.isEmpty else {
            setStatus("⚠️ 请先填写接口地址和 API Key", .systemOrange); return
        }
        busy = true
        setStatus("正在获取模型列表…", .secondaryLabelColor)
        Task { [weak self] in
            do {
                let list = try await AIClient.fetchModels(endpoint: ep, key: key)
                await MainActor.run {
                    guard let self = self else { return }
                    self.busy = false
                    self.modelBox.removeAllItems()
                    self.modelBox.addItems(withObjectValues: list)
                    if self.modelBox.stringValue.isEmpty, let first = list.first {
                        self.modelBox.stringValue = first
                        self.saveFields()
                    }
                    self.setStatus(list.isEmpty ? "接口没有返回模型列表，请手动填写模型名称"
                                                : "✅ 获取到 \(list.count) 个模型：\(list.prefix(6).joined(separator: "、"))\(list.count > 6 ? " …" : "")",
                                   list.isEmpty ? .systemOrange : .secondaryLabelColor)
                    if !list.isEmpty { self.modelBox.becomeFirstResponder() }
                }
            } catch {
                await MainActor.run {
                    self?.busy = false
                    self?.setStatus("❌ 获取失败：\(AIClient.describe(error))。可以手动填写模型名称",
                                    .systemRed)
                }
            }
        }
    }

    @objc private func testConnection() {
        saveFields()
        let ep = AISettings.endpoint, key = AISettings.apiKey, model = AISettings.model
        guard AISettings.chatURL(from: ep) != nil, !key.isEmpty, !model.isEmpty else {
            setStatus("⚠️ 请先填写接口地址、API Key 和模型", .systemOrange); return
        }
        busy = true
        setStatus("正在测试…", .secondaryLabelColor)
        let thinking = AISettings.thinking
        Task { [weak self] in
            do {
                let (text, t) = try await AIClient.test(endpoint: ep, key: key, model: model, thinking: thinking)
                await MainActor.run {
                    self?.busy = false
                    let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.setStatus(String(format: "✅ 连接成功，用时 %.1f 秒。模型回复：%@", t,
                                           reply.isEmpty ? "（空）" : String(reply.prefix(40))),
                                    .systemGreen)
                }
            } catch {
                await MainActor.run {
                    self?.busy = false
                    self?.setStatus("❌ " + AIClient.describe(error), .systemRed)
                }
            }
        }
    }

    @objc private func importCurl() {
        let alert = NSAlert()
        alert.messageText = "从 curl 命令导入"
        alert.informativeText = "粘贴服务商提供的 curl 示例，会自动提取接口地址、API Key 和模型。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard let w = window else { return }
        alert.window.initialFirstResponder = tv
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            let r = AISettings.parseCurl(tv.string)
            var got: [String] = []
            if let ep = r.endpoint { self.endpointField.stringValue = ep; got.append("接口地址") }
            if let k = r.key {
                self.keyField.stringValue = k; self.keyPlainField.stringValue = k; got.append("API Key")
            }
            if let m = r.model { self.modelBox.stringValue = m; got.append("模型") }
            self.saveFields()
            if got.isEmpty {
                self.setStatus("⚠️ 没有识别到接口地址、Key 或模型", .systemOrange)
            } else {
                self.setStatus("✅ 已导入：\(got.joined(separator: "、"))。可以点「测试连接」确认是否可用。", .systemGreen)
            }
        }
    }

    @objc private func thinkingChanged() {
        if let raw = thinkingPopup.selectedItem?.representedObject as? String, let t = AISettings.Thinking(rawValue: raw) {
            AISettings.thinking = t
        }
    }

    @objc private func sourcesChanged() {
        let list = WebSearcher.Source.allCases.filter { sourceChecks[$0]?.state == .on }
        AISettings.sources = list
        if list.isEmpty { setStatus("⚠️ 没有勾选搜索来源时，AI 搜索会使用搜狗和 360", .systemOrange) }
    }

    @objc private func countChanged() {
        AISettings.resultCount = countPopup.selectedTag()
    }

    @objc private func historyChanged() {
        AISettings.historyEnabled = historyCheck.state == .on
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空 AI 历史？"
        alert.informativeText = "共 \(AIHistoryStore.shared.sessions.count) 条记录，清空后无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { resp in
            if resp == .alertFirstButtonReturn { AIHistoryStore.shared.clear() }
        }
    }
}
