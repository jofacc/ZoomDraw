import AppKit
import QuickLookThumbnailing

/// 文件搜索右侧的预览：缩略图（图片 / PDF / 文档首页等）、名称、类型、大小、日期、位置
final class FilePreviewPane: NSView {
    static let width: CGFloat = 300

    private let sep = NSView()
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    private var shown: URL?
    private var token = 0
    private var pending: DispatchWorkItem?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)

        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.isSelectable = false
        addSubview(nameLabel)

        infoLabel.font = NSFont.systemFont(ofSize: 11.5)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.maximumNumberOfLines = 0
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.isSelectable = false
        addSubview(infoLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        sep.frame = NSRect(x: 0, y: 0, width: 1, height: H)
        let pad: CGFloat = 18
        let inner = W - pad * 2 - 1
        let imgH = max(80, min(inner, H - 150))
        imageView.frame = NSRect(x: pad + 1, y: H - 14 - imgH, width: inner, height: imgH)
        // 文字紧贴图片下方、从上往下排（按内容算高度，避免文字在大框里垂直居中）
        func fit(_ l: NSTextField, maxH: CGFloat) -> CGFloat {
            let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10000)).height ?? 16
            return min(ceil(h), maxH)
        }
        let nameH = fit(nameLabel, maxH: 54)
        nameLabel.frame = NSRect(x: pad + 1, y: imageView.frame.minY - 10 - nameH, width: inner, height: nameH)
        let infoH = fit(infoLabel, maxH: max(0, nameLabel.frame.minY - 6 - 8))
        infoLabel.frame = NSRect(x: pad + 1, y: nameLabel.frame.minY - 6 - infoH, width: inner, height: infoH)
    }

    /// 显示某个文件；nil 清空。缩略图稍作延迟再生成，方向键连续切换时不会每一项都去生成
    func show(_ url: URL?) {
        if url == shown { return }
        shown = url
        token += 1
        pending?.cancel()
        guard let url = url else {
            imageView.image = nil
            nameLabel.stringValue = ""
            infoLabel.stringValue = ""
            return
        }
        let t = token
        imageView.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.stringValue = FileManager.default.displayName(atPath: url.path)
        infoLabel.stringValue = FileSearchSettings.abbreviate(url.deletingLastPathComponent().path)
        needsLayout = true

        let work = DispatchWorkItem { [weak self] in
            self?.load(url, token: t)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func load(_ url: URL, token t: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let side = max(160, imageView.bounds.width)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                               scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self = self, self.token == t else { return }
                self.imageView.image = img
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Self.details(url)
            DispatchQueue.main.async {
                guard let self = self, self.token == t else { return }
                self.infoLabel.stringValue = text
                self.needsLayout = true
            }
        }
    }

    private static func details(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey, .isPackageKey,
                                         .contentModificationDateKey, .creationDateKey]
        let v = try? url.resourceValues(forKeys: keys)
        var lines: [String] = []
        if let kind = v?.localizedTypeDescription { lines.append("类型：\(kind)") }
        let isFolder = v?.isDirectory == true && v?.isPackage != true
        if isFolder {
            if let n = try? FileManager.default.contentsOfDirectory(atPath: url.path).filter({ !$0.hasPrefix(".") }).count {
                lines.append("包含：\(n) 项")
            }
        } else if let size = v?.fileSize {
            lines.append("大小：" + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let d = v?.contentModificationDate { lines.append("修改：" + dateFormatter.string(from: d)) }
        if let d = v?.creationDate { lines.append("创建：" + dateFormatter.string(from: d)) }
        lines.append("位置：" + FileSearchSettings.abbreviate(url.deletingLastPathComponent().path))
        return lines.joined(separator: "\n")
    }
}
