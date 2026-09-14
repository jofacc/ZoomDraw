import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// 录屏流程编排：录制指示边框 + 悬浮控制条 + 导出（MP4 / GIF）
final class RecordingController {
    static let shared = RecordingController()

    private let recorder = ScreenRecorder()
    private var borderWindow: NSWindow?
    private var controlWindow: NSWindow?
    private var controlBar: RecordingControlBar?
    private var ticker: Timer?

    private var startedAt: Date = .distantPast
    private var pausedDuration: TimeInterval = 0
    private var pausedAt: Date?

    private(set) var isRecording = false
    /// 录制状态变化（供菜单栏更新图标）
    var onStateChange: ((Bool) -> Void)?

    private init() {
        recorder.onStreamStopped = { [weak self] error in
            guard let self = self, self.isRecording else { return }
            self.finishAndExport(failureHint: error.localizedDescription)
        }
    }

    // MARK: - 开始
    /// - Parameters:
    ///   - screen: 目标屏幕
    ///   - localRect: 录制区域（屏幕本地坐标，左下原点）
    func start(screen: NSScreen, localRect: NSRect) {
        guard !isRecording else { return }
        let rect = localRect.integral
        guard rect.width >= 16, rect.height >= 16 else {
            ScreenshotToast.show("录制区域太小")
            return
        }

        isRecording = true
        let global = NSRect(x: rect.minX + screen.frame.minX,
                            y: rect.minY + screen.frame.minY,
                            width: rect.width, height: rect.height)
        showBorder(global)
        showControlBar(around: global, on: screen)
        onStateChange?(true)

        Task { @MainActor in
            do {
                try await recorder.start(screen: screen, rect: rect)
                startedAt = Date()
                pausedDuration = 0
                pausedAt = nil
                startTicker()
            } catch {
                self.teardownUI()
                self.isRecording = false
                self.onStateChange?(false)
                let alert = NSAlert()
                alert.messageText = "无法开始录屏"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - 控制
    func togglePause() {
        guard isRecording else { return }
        if recorder.isPaused {
            if let p = pausedAt { pausedDuration += Date().timeIntervalSince(p) }
            pausedAt = nil
            recorder.setPaused(false)
        } else {
            pausedAt = Date()
            recorder.setPaused(true)
        }
        controlBar?.isPaused = recorder.isPaused
    }

    func stop() {
        finishAndExport(failureHint: nil)
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        stopTicker()
        teardownUI()
        onStateChange?(false)
        Task { await recorder.cancel() }
        ScreenshotToast.show("已取消录屏")
    }

    private func finishAndExport(failureHint: String?) {
        guard isRecording else { return }
        isRecording = false
        stopTicker()
        teardownUI()
        onStateChange?(false)

        Task { @MainActor in
            do {
                let url = try await recorder.finish()
                if let hint = failureHint {
                    ScreenshotToast.show("录制中断：\(hint)")
                }
                self.presentExportPanel(for: url)
            } catch {
                ScreenshotToast.show(error.localizedDescription)
            }
        }
    }

    // MARK: - 计时
    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.controlBar?.elapsed = self.elapsedSeconds
            self.controlBar?.blink()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private var elapsedSeconds: TimeInterval {
        guard startedAt > .distantPast else { return 0 }
        var paused = pausedDuration
        if let p = pausedAt { paused += Date().timeIntervalSince(p) }
        return max(0, Date().timeIntervalSince(startedAt) - paused)
    }

    // MARK: - 指示 UI
    private func showBorder(_ global: NSRect) {
        let outer = global.insetBy(dx: -3, dy: -3)
        let win = NSWindow(contentRect: outer, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.contentView = RecordingBorderView(frame: NSRect(origin: .zero, size: outer.size))
        win.orderFrontRegardless()
        borderWindow = win
    }

    private func showControlBar(around global: NSRect, on screen: NSScreen) {
        let bar = RecordingControlBar(frame: .zero)
        bar.onPause = { [weak self] in self?.togglePause() }
        bar.onStop = { [weak self] in self?.stop() }
        bar.onCancel = { [weak self] in self?.cancel() }

        let size = bar.intrinsicSize
        var origin = NSPoint(x: global.midX - size.width / 2, y: global.minY - size.height - 12)
        if origin.y < screen.frame.minY + 8 { origin.y = global.maxY + 12 }
        if origin.y + size.height > screen.frame.maxY - 8 {
            origin.y = max(screen.frame.minY + 8, global.minY + 12)
        }
        origin.x = max(screen.frame.minX + 8, min(screen.frame.maxX - size.width - 8, origin.x))

        let win = RecordingControlWindow(contentRect: NSRect(origin: origin, size: size),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        bar.frame = NSRect(origin: .zero, size: size)
        win.contentView = bar
        win.onStop = { [weak self] in self?.stop() }
        win.onCancel = { [weak self] in self?.cancel() }
        win.onPause = { [weak self] in self?.togglePause() }
        win.orderFrontRegardless()
        controlWindow = win
        controlBar = bar
    }

    private func teardownUI() {
        borderWindow?.orderOut(nil); borderWindow = nil
        controlWindow?.orderOut(nil); controlWindow = nil
        controlBar = nil
    }

    // MARK: - 导出
    private func presentExportPanel(for tempURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .gif]
        panel.nameFieldStringValue = "录屏 \(Self.timestamp()).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.title = "导出录屏"
        panel.message = "在「文件格式」中可选择 MP4 视频或 GIF 动图"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        if dest.pathExtension.lowercased() == "gif" {
            ScreenshotToast.show("正在生成 GIF…", duration: 2.2)
            Task.detached(priority: .userInitiated) {
                do {
                    try await GIFExporter.export(movie: tempURL, to: dest)
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { ScreenshotToast.show("已保存 \(dest.lastPathComponent)") }
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "GIF 导出失败"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        } else {
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                ScreenshotToast.show("已保存 \(dest.lastPathComponent)")
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}

// MARK: - 录制边框
private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineDash(phase: 0, lengths: [9, 5])
        ctx.stroke(r)
    }
}

// MARK: - 控制条
private final class RecordingControlWindow: NSWindow {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()            // ESC
        case 36, 76: onStop?()          // Return
        case 49: onPause?()             // Space
        default: super.keyDown(with: event)
        }
    }
}

final class RecordingControlBar: NSView {
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    var elapsed: TimeInterval = 0 { didSet { needsDisplay = true } }
    var isPaused = false { didSet { needsDisplay = true } }

    private var dotOn = true
    private var hover = -1 { didSet { needsDisplay = true } }
    private var buttonRects: [Int: NSRect] = [:]

    private let btnW: CGFloat = 30
    private let btnH: CGFloat = 26
    private let pad: CGFloat = 10

    var intrinsicSize: NSSize { NSSize(width: 214, height: 40) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func blink() {
        if !isPaused { dotOn.toggle() } else { dotOn = true }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        buttonRects.removeAll()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                      color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 0.95).cgColor)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2,
                           cornerHeight: bounds.height / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // 红点 + 计时
        let dot = NSRect(x: pad + 2, y: bounds.midY - 4, width: 8, height: 8)
        ctx.setFillColor((isPaused ? NSColor.systemOrange
                                   : NSColor.systemRed.withAlphaComponent(dotOn ? 1 : 0.25)).cgColor)
        ctx.fillEllipse(in: dot)

        let text = Self.format(elapsed) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let ts = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: dot.maxX + 7, y: bounds.midY - ts.height / 2), withAttributes: attrs)

        // 按钮：暂停 / 停止 / 取消
        var x = bounds.width - pad - btnW * 3 - 8
        let y = bounds.midY - btnH / 2
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.fill(NSRect(x: x - 9, y: bounds.minY + 11, width: 1, height: bounds.height - 22))

        let specs: [(Int, String, NSColor)] = [
            (0, isPaused ? "play.fill" : "pause.fill", .white),
            (1, "stop.fill", NSColor.systemRed),
            (2, "xmark", NSColor.white.withAlphaComponent(0.75))
        ]
        for (i, symbol, color) in specs {
            let r = NSRect(x: x, y: y, width: btnW, height: btnH)
            buttonRects[i] = r
            if hover == i {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }
            drawSymbol(symbol, in: r, color: color)
            x += btnW + 4
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return }
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: 交互
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in buttonRects where r.contains(p) {
            switch i {
            case 0: onPause?()
            case 1: onStop?()
            default: onCancel?()
            }
            return
        }
        // 空白区域拖动窗口
        window?.performDrag(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var found = -1
        for (i, r) in buttonRects where r.contains(p) { found = i }
        hover = found
        toolTip = ["暂停 / 继续 (Space)", "结束并导出 (⏎)", "取消录屏 (ESC)"][safe: found]
    }

    override func mouseExited(with event: NSEvent) { hover = -1 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - GIF 导出
enum GIFExporter {
    /// 把 MP4 转成循环播放的 GIF
    static func export(movie: URL, to dest: URL, maxWidth: CGFloat = 900, preferredFPS: Double = 12) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "ZoomDraw", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "视频时长无效"])
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "ZoomDraw", code: -21,
                          userInfo: [NSLocalizedDescriptionKey: "未找到视频轨道"])
        }
        let natural = try await track.load(.naturalSize)

        // 控制帧数上限，避免 GIF 体积失控
        let maxFrames = 450.0
        let fps = max(4, min(preferredFPS, maxFrames / duration))
        let frameCount = max(1, Int(duration * fps))
        let delay = 1.0 / fps

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        let ratio = min(1, maxWidth / max(natural.width, 1))
        generator.maximumSize = CGSize(width: (natural.width * ratio).rounded(),
                                       height: (natural.height * ratio).rounded())

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL,
                                                        UTType.gif.identifier as CFString,
                                                        frameCount, nil) else {
            throw NSError(domain: "ZoomDraw", code: -22,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 GIF 文件"])
        }
        CGImageDestinationSetProperties(out, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ] as CFDictionary

        var written = 0
        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(out, image, frameProps)
            written += 1
        }
        guard written > 0, CGImageDestinationFinalize(out) else {
            throw NSError(domain: "ZoomDraw", code: -23,
                          userInfo: [NSLocalizedDescriptionKey: "GIF 写入失败"])
        }
    }
}
