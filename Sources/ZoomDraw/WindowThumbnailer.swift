import AppKit
import ScreenCaptureKit

/// 窗口缩略图截取与缓存（仅在主线程访问）
final class WindowThumbnailer {
    static let shared = WindowThumbnailer()

    private struct Entry { let image: NSImage; let at: Date }
    private var cache: [CGWindowID: Entry] = [:]
    private var content: (value: AnyObject, at: Date)?

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> NSImage? {
        id == 0 ? nil : cache[id]?.image
    }

    /// 截取一组窗口，每张图完成后回调一次（主线程）。
    /// 最小化的窗口截不到画面，只用缓存；`maxAge` 内截过的直接复用。
    func refresh(_ windows: [WindowInfo], maxPixel: CGFloat, maxAge: TimeInterval = 1.5,
                 onImage: @escaping (CGWindowID, NSImage) -> Void) {
        guard #available(macOS 14.0, *), Self.hasScreenRecordingPermission else { return }
        let now = Date()
        let targets = windows.filter {
            $0.windowID != 0 && !$0.isMinimized
                && (cache[$0.windowID].map { now.timeIntervalSince($0.at) > maxAge } ?? true)
        }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.windowID)

        Task { @MainActor in
            guard let content = await self.shareableContent() else { return }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in ids {
                    guard let scw = content.windows.first(where: { $0.windowID == id }) else { continue }
                    group.addTask { (id, try? await Self.capture(scw, maxPixel: maxPixel)) }
                }
                for await (id, cg) in group {
                    guard let cg = cg, !Self.isBlank(cg) else { continue }
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache[id] = Entry(image: img, at: Date())
                    onImage(id, img)
                }
            }
            self.prune()
        }
    }

    @available(macOS 14.0, *)
    @MainActor
    private func shareableContent() async -> SCShareableContent? {
        if let c = content, Date().timeIntervalSince(c.at) < 1.0, let v = c.value as? SCShareableContent { return v }
        guard let v = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return nil
        }
        content = (v, Date())
        return v
    }

    @available(macOS 14.0, *)
    private static func capture(_ w: SCWindow, maxPixel: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let f = w.frame
        let scale = min(2, maxPixel / max(f.width, f.height, 1))
        cfg.width = max(1, Int(f.width * scale))
        cfg.height = max(1, Int(f.height * scale))
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// 截到全透明画面（窗口不可截取时会这样）视为失败
    private static func isBlank(_ img: CGImage) -> Bool {
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return !stride(from: 3, to: px.count, by: 4).contains { px[$0] > 8 }
    }

    private func prune() {
        guard cache.count > 300 else { return }
        let keep = cache.sorted { $0.value.at > $1.value.at }.prefix(200)
        cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
