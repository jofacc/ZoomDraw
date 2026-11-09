import AppKit

/// 「关于与使用说明」合并窗口：上方版本信息，下方可滚动的使用说明
final class AboutHelpWindowController: NSWindowController {
    static let shared = AboutHelpWindowController()

    private let textView = NSTextView()
    private let versionLabel = NSTextField(labelWithString: "")

    private static let size = NSSize(width: 540, height: 620)
    private static let headerH: CGFloat = 112

    private convenience init() {
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "关于与使用说明"
        win.minSize = NSSize(width: 440, height: 360)
        win.isReleasedWhenClosed = false
        self.init(window: win)
        build()
    }

    func show() {
        refresh()
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        textView.scrollToBeginningOfDocument(nil)
    }

    // MARK: 构建
    private func build() {
        guard let content = window?.contentView else { return }
        let W = content.bounds.width, H = content.bounds.height

        let header = NSView(frame: NSRect(x: 0, y: H - Self.headerH, width: W, height: Self.headerH))
        header.autoresizingMask = [.width, .minYMargin]
        content.addSubview(header)

        let icon = NSImageView(frame: NSRect(x: 24, y: 24, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        header.addSubview(icon)

        let name = NSTextField(labelWithString: "ZoomDraw")
        name.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        name.frame = NSRect(x: 104, y: 62, width: 200, height: 28)
        header.addSubview(name)

        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 104, y: 44, width: 300, height: 16)
        header.addSubview(versionLabel)

        let desc = NSTextField(labelWithString: "轻量的屏幕放大、截图、录屏、标注、文件暂存、剪贴板历史与窗口预览工具")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.frame = NSRect(x: 104, y: 24, width: W - 104 - 20, height: 16)
        desc.autoresizingMask = [.width]
        desc.lineBreakMode = .byTruncatingTail
        header.addSubview(desc)

        let copyright = NSTextField(labelWithString: "© tywinliu，保留所有权利")
        copyright.font = NSFont.systemFont(ofSize: 11)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .right
        copyright.frame = NSRect(x: W - 220, y: 68, width: 200, height: 16)
        copyright.autoresizingMask = [.minXMargin]
        header.addSubview(copyright)

        let sep = NSBox(frame: NSRect(x: 0, y: H - Self.headerH, width: W, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        content.addSubview(sep)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: H - Self.headerH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = textView
        content.addSubview(scroll)
    }

    /// 每次打开都重新生成：快捷键可能已在偏好设置中修改
    private func refresh() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        versionLabel.stringValue = "版本 \(short)（build \(build)）"
        textView.textStorage?.setAttributedString(Self.helpText())
    }

    // MARK: 使用说明
    private static func key(_ a: HotkeyAction) -> String {
        HotkeyConfig.shared.binding(for: a).displayString
    }

    private static func sections() -> [(String, [String])] {
        [
            ("全局快捷键（可在「偏好设置」中修改）", [
                "\(key(.zoom))  开/关 放大模式",
                "\(key(.draw))  开/关 画笔标注",
                "\(key(.shot))  截图 / 录屏",
                "\(key(.shelf))  开/关 暂存板",
                "\(key(.shelfPaste))  剪贴板内容存入暂存板",
                "\(key(.clipboard))  开/关 剪贴板历史",
                "\(key(.windowSwitcher))  窗口切换器",
                "\(key(.dockPreview))  开/关 程序坞预览",
            ]),
            ("放大模式", [
                "鼠标移动跟随焦点；滚轮或 + - 调节倍率（1× – 8×）",
                "左键单击暂停画面，并自动进入画笔叠加；ESC 退出",
                "暂停后：H 或 Tab 隐藏/显示画笔 · 1–5 红/黄/绿/蓝/白 · [ ] 笔触",
                "A 自由 · B 矩形 · C 椭圆 · D 箭头 · Z 撤销 · X 清空当前画面",
            ]),
            ("截图", [
                "拖动框选；单击自动选中鼠标下最上层的窗口",
                "放大镜实时取色，显示坐标与 HEX",
                "选区确定后拖控制点微调，拖内部整体移动；双击选区立即完成并复制",
                "工具：矩形 B · 椭圆 C · 箭头 D · 画笔 A · 马赛克 M · 文字 T",
                "1–6 切换颜色 · [ ] 粗细 · ⌘Z 撤销 · ⌘A 全屏 · 右键重新框选",
                "⏎ 或 ⌘C 完成并复制 · ⌘S 保存 PNG · ESC 逐级退出（文字 → 选区 → 截图）",
                "卡住退不出时：连按 3 次 ESC 强制退出；也可再按一次截图快捷键，或点菜单栏「强制关闭遮罩」",
            ]),
            ("录屏（选好区域后点工具栏红色圆点，或按 ⌘R）", [
                "录制区域显示红色虚线边框，附带悬浮控制条",
                "Space 暂停/继续 · ⏎ 结束并导出 · ESC 取消",
                "可导出为 MP4 视频或 GIF 动图",
                "录屏中再按截图快捷键 = 立即结束并导出",
            ]),
            ("暂存板（跨应用搬运文件的中转站）", [
                "拖入文件、文本、图片、网址，再从暂存板拖到目标应用",
                "拖动文件时自动浮现（可在偏好设置中关闭）",
                "拖到屏幕左/右/上边缘松手自动收起，点细条或按快捷键拉回",
                "停靠状态下召唤出来，鼠标离开后按设定秒数自动收回",
                "空白处拖动拉框多选（⌘/⇧ 追加）",
                "双击打开 · Delete 移除 · ⌘A 全选 · ⌘C 复制 · ⌘V 粘贴",
                "右键：在 Finder 中显示 / 清理失效条目 / 清空",
            ]),
            ("剪贴板历史", [
                "自动记录复制过的文本、链接、颜色、图片、文件",
                "打开后直接输入即可搜索；Tab / ⇧Tab 切换分类",
                "⏎ 粘贴 · ⇧⏎ 纯文本粘贴 · ⌥1–9 粘贴第 N 条",
                "⌘C 仅复制 · ⌘P 固定 · ⌘⌫ 删除 · ⌘S 存入暂存板 · ⌘O 打开",
                "条目可直接拖到其他应用",
                "菜单栏「剪贴板记录」可暂停记录或清除最近记录",
            ]),
            ("AI 搜索与快捷搜索（在剪贴板历史的输入框中使用）", [
                "输入内容后按 ⌘1–⌘9：默认 ⌘1 AI 搜索 · ⌘2 百度地图 · ⌘3 翻译 · ⌘4 解释 · ⌘5 总结 · ⌘6 润色 · ⌘7 识别图片",
                "输入框为空时处理当前选中的条目；选中图片时由 AI 识别图片",
                "AI 搜索：联网搜索（搜狗 / 360 / DuckDuckGo 的标题和摘要）后由 AI 回答，标注来源角标，悬停查看、点击打开",
                "回答界面：⏎ 追问 · 输入框为空时 ⏎ 粘贴回答 · ⇧⏎ 粘贴 Markdown · ⌘C 复制 · ⌘P 钉住为独立窗口 · ⌘R 重新生成 · Esc 停止 / 返回",
                "AI 历史在分类「✦ AI 历史」中，⏎ 打开后可继续追问",
                "需先在「偏好设置 → AI」中填写接口地址、API Key（保存在钥匙串）和模型",
                "模板在「偏好设置 → 快捷搜索」中添加、修改、排序；可自定义 AI 指令的提示词",
                "面板打开期间 ZoomDraw 的其他全局快捷键暂停，⌘1–9 一定用于快捷搜索",
            ]),
            ("程序坞预览", [
                "鼠标停在程序坞图标上，弹出该应用所有窗口的缩略图（程序坞在左/右侧时显示在旁边）",
                "点击缩略图切换到该窗口，最小化的窗口会先还原",
                "鼠标移到缩略图上显示 关闭 / 最小化 / 全屏 按钮；右上角「退出」退出整个应用",
                "鼠标进入预览后：←→↑↓ 选择 · ⏎ 切换 · ESC 关闭",
                "其他桌面上的窗口点击后切到对应应用",
                "延迟、大小、显示内容、不显示预览的应用可在「偏好设置 → 程序坞」调整",
                "开启「台前调度」时自动暂停",
            ]),
            ("窗口切换器（跨应用按窗口切换）", [
                "按住修饰键连按 \(key(.windowSwitcher)) 选择窗口，松开即切换；按一下即在最近两个窗口间来回",
                "⇧ 反向 · 方向键移动 · 鼠标点击直接切换",
                "W 关闭窗口 · M 最小化/还原 · Q 退出应用 · ESC 取消",
                "也可从菜单栏「窗口切换器」打开，此时用 ⏎ 确认",
            ]),
            ("独立画笔标注", [
                "鼠标拖拽绘制；同样支持 1–5 / A B C D / Z / X / ESC",
            ]),
            ("权限", [
                "放大 / 截图 / 录屏：需要「屏幕录制」权限",
                "剪贴板自动粘贴：需要「辅助功能」权限；未授权时只复制",
                "程序坞预览 / 窗口切换器：需要「辅助功能」权限；缩略图画面需要「屏幕录制」权限，未授权时显示应用图标",
                "均在 系统设置 → 隐私与安全性 中勾选 ZoomDraw",
            ]),
        ]
    }

    private static func helpText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacingBefore = 12
        titleStyle.paragraphSpacing = 4
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.headIndent = 14
        bodyStyle.firstLineHeadIndent = 0
        bodyStyle.lineSpacing = 2
        bodyStyle.paragraphSpacing = 2
        bodyStyle.tabStops = [NSTextTab(textAlignment: .left, location: 14)]

        for (i, (title, lines)) in sections().enumerated() {
            let t = NSMutableParagraphStyle()
            t.setParagraphStyle(titleStyle)
            if i == 0 { t.paragraphSpacingBefore = 0 }
            out.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: t,
            ]))
            for line in lines {
                out.append(NSAttributedString(string: "•\t" + line + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: bodyStyle,
                ]))
            }
        }
        return out
    }
}
