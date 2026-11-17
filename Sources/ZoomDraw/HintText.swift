import AppKit

/// 底部快捷键提示的统一样式（文件搜索、剪贴板历史共用）：按键加粗醒目，说明文字稍淡
enum HintText {
    static let font = NSFont.systemFont(ofSize: 12)

    static func make(prefix: String? = nil, _ pairs: [(String, String)], gap: String = "    ") -> NSAttributedString {
        let out = NSMutableAttributedString()
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        if let prefix = prefix {
            out.append(NSAttributedString(string: prefix + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        for (i, (k, d)) in pairs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: gap, attributes: descAttrs)) }
            out.append(NSAttributedString(string: k, attributes: keyAttrs))
            out.append(NSAttributedString(string: " " + d, attributes: descAttrs))
        }
        return out
    }
}
