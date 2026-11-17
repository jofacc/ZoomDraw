import AppKit

/// 偏好设置 →「权限」标签页：一眼看到每项系统权限是否已授权、哪些功能需要它
final class PermissionsPrefsPane: NSView {
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    private let summary = NSTextField(labelWithString: "")
    private let list = FlippedView()
    private var items: [PermissionInfo] = []
    private var keyObserver: NSObjectProtocol?
    private var permObserver: NSObjectProtocol?
    private var refreshing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]

        summary.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        summary.frame = NSRect(x: 20, y: bounds.height - 34, width: bounds.width - 40, height: 20)
        summary.autoresizingMask = [.minYMargin]
        addSubview(summary)

        list.frame = NSRect(x: 0, y: 44, width: bounds.width, height: bounds.height - 90)
        list.autoresizingMask = [.width, .height]
        addSubview(list)

        let hint = NSTextField(labelWithString: "授权在系统设置中勾选后会自动刷新；已授权的项目无需操作")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 16, width: bounds.width - 40 - 130, height: 16)
        hint.autoresizingMask = [.maxYMargin]
        addSubview(hint)

        let reload = NSButton(title: "重新检测", target: self, action: #selector(refresh))
        reload.bezelStyle = .rounded
        reload.frame = NSRect(x: bounds.width - 20 - 100, y: 10, width: 100, height: 28)
        reload.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(reload)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        [keyObserver, permObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        if let o = permObserver { NotificationCenter.default.removeObserver(o); permObserver = nil }
        guard let w = window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        permObserver = NotificationCenter.default.addObserver(
            forName: .permissionsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        refresh()
    }

    // MARK: 刷新

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Permissions.snapshot { [weak self] result in
            guard let self = self else { return }
            self.refreshing = false
            self.items = result
            self.render()
        }
    }

    private func render() {
        let needed = items.filter { !$0.isOptional }
        let ready = needed.filter { $0.status.isReady }.count
        if ready == needed.count {
            summary.stringValue = "必需权限已全部就绪（\(ready)/\(needed.count)）"
            summary.textColor = .systemGreen
        } else {
            summary.stringValue = "必需权限已就绪 \(ready)/\(needed.count)，有 \(needed.count - ready) 项需要处理"
            summary.textColor = .systemOrange
        }

        list.subviews.forEach { $0.removeFromSuperview() }
        let W = list.bounds.width
        let pad: CGFloat = 20
        let btnW: CGFloat = 96
        let textX = pad + 34
        let textW = W - textX - btnW - pad - 14
        var y: CGFloat = 4

        for (i, info) in items.enumerated() {
            let top = y

            let icon = NSImageView(frame: NSRect(x: pad, y: top + 2, width: 24, height: 24))
            icon.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            icon.contentTintColor = tint(info.status)
            list.addSubview(icon)

            let title = NSTextField(labelWithString: info.title)
            title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            title.sizeToFit()
            title.frame.origin = NSPoint(x: textX, y: top + 2)
            list.addSubview(title)

            let badge = NSTextField(labelWithString: badgeText(info.status))
            badge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            badge.textColor = tint(info.status)
            badge.sizeToFit()
            badge.frame.origin = NSPoint(x: title.frame.maxX + 10, y: top + 3)
            list.addSubview(badge)

            var ty = top + 24
            func addText(_ prefix: String, _ text: String, color: NSColor) {
                let l = NSTextField(wrappingLabelWithString: "\(prefix)\(text)")
                l.font = NSFont.systemFont(ofSize: 11)
                l.textColor = color
                l.preferredMaxLayoutWidth = textW
                let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 1000)).height ?? 14
                l.frame = NSRect(x: textX, y: ty, width: textW, height: ceil(h))
                list.addSubview(l)
                ty += ceil(h) + 2
            }
            if case .notNeeded(let why) = info.status {
                addText("", why, color: .secondaryLabelColor)
            } else {
                addText("用于：", info.features, color: .secondaryLabelColor)
                if !info.status.isReady {
                    addText("未授权时：", info.impact, color: .tertiaryLabelColor)
                }
            }

            if let title = buttonTitle(info) {
                let b = ActionButton(title: title) { [weak self] in
                    Permissions.perform(info)
                    self?.refresh()
                }
                b.frame = NSRect(x: W - pad - btnW, y: top, width: btnW, height: 26)
                list.addSubview(b)
            }

            y = max(ty, top + 30) + 10
            if i < items.count - 1 {
                let sep = NSBox(frame: NSRect(x: pad, y: y - 5, width: W - pad * 2, height: 1))
                sep.boxType = .separator
                list.addSubview(sep)
            }
        }
    }

    private func tint(_ s: PermissionStatus) -> NSColor {
        switch s {
        case .granted: return .systemGreen
        case .missing: return .systemRed
        case .optionalMissing, .notNeeded: return .secondaryLabelColor
        case .warning, .restartNeeded: return .systemOrange
        }
    }

    private func badgeText(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "✓ 已授权"
        case .missing: return "✗ 未授权"
        case .optionalMissing: return "未授权（可选）"
        case .warning(let why): return "⚠ \(why)"
        case .restartNeeded: return "⚠ 已授权，需重启生效"
        case .notNeeded: return "无需授权"
        }
    }

    private func buttonTitle(_ info: PermissionInfo) -> String? {
        switch info.status {
        case .granted, .notNeeded: return nil
        case .restartNeeded: return "重启应用"
        case .warning: return "打开设置…"
        case .missing, .optionalMissing:
            return info.id == .pasteboard || info.id == .fullDisk ? "打开设置…" : "去授权…"
        }
    }
}

/// 带闭包的按钮
private final class ActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = NSFont.systemFont(ofSize: 12)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
