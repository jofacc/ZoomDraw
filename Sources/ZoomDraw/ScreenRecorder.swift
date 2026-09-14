import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 区域录屏核心：ScreenCaptureKit 采集 + AVAssetWriter 实时编码为 H.264/MP4
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private let sampleQueue = DispatchQueue(label: "com.zoomdraw.recorder.samples")

    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var pausedOffset: CMTime = .zero
    private var pauseWallClock: CFTimeInterval = 0
    private var frameCount = 0

    private(set) var isPaused = false
    private(set) var outputURL: URL?
    private(set) var pixelSize: CGSize = .zero
    private(set) var fps: Int = 30

    /// 采集流意外中断（例如分辨率变化）
    var onStreamStopped: ((Error) -> Void)?

    // MARK: - 生命周期
    /// - Parameters:
    ///   - screen: 目标屏幕
    ///   - rect: 录制区域（该屏幕的本地坐标，左下原点）
    func start(screen: NSScreen, rect: NSRect, fps: Int = 30) async throws {
        self.fps = fps

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let dispID = ScreenCapture.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == dispID }) ?? content.displays.first else {
            throw NSError(domain: "ZoomDraw", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
        }

        // 把 ZoomDraw 自己的窗口（边框指示、控制条）排除在录制画面之外
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let me = content.applications.first(where: { $0.processID == selfPID }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let scale = screen.backingScaleFactor
        let region = rect.integral
        let cfg = SCStreamConfiguration()
        // sourceRect 以显示器左上角为原点（单位 point）
        cfg.sourceRect = CGRect(x: region.minX,
                                y: screen.frame.height - region.maxY,
                                width: region.width,
                                height: region.height)
        cfg.width = Self.evenValue(region.width * scale)
        cfg.height = Self.evenValue(region.height * scale)
        cfg.scalesToFit = false
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        pixelSize = CGSize(width: cfg.width, height: cfg.height)

        // 输出文件（临时目录，导出时再按用户选择转存）
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomDraw-Recording-\(UUID().uuidString).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(2_500_000, Int(Double(cfg.width * cfg.height) * 4.5))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: cfg.width,
            AVVideoHeightKey: cfg.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else {
            throw NSError(domain: "ZoomDraw", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "无法初始化视频编码器"])
        }
        w.add(input)
        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "ZoomDraw", code: -12,
                                     userInfo: [NSLocalizedDescriptionKey: "无法写入临时文件"])
        }

        writer = w
        videoInput = input
        outputURL = url
        sessionStarted = false
        firstPTS = .invalid
        pausedOffset = .zero
        isPaused = false
        frameCount = 0

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
    }

    func setPaused(_ paused: Bool) {
        sampleQueue.sync {
            guard paused != isPaused else { return }
            if paused {
                pauseWallClock = CACurrentMediaTime()
            } else if pauseWallClock > 0 {
                let delta = CACurrentMediaTime() - pauseWallClock
                pausedOffset = CMTimeAdd(pausedOffset, CMTime(seconds: delta, preferredTimescale: 600))
            }
            isPaused = paused
        }
    }

    /// 结束录制并返回临时 MP4 路径
    func finish() async throws -> URL {
        if let s = stream { try? await s.stopCapture() }
        stream = nil

        guard let w = writer, let input = videoInput, let url = outputURL else {
            throw NSError(domain: "ZoomDraw", code: -13,
                          userInfo: [NSLocalizedDescriptionKey: "录制尚未开始"])
        }
        let captured = sampleQueue.sync { frameCount }
        guard captured > 0 else {
            w.cancelWriting()
            reset()
            throw NSError(domain: "ZoomDraw", code: -14,
                          userInfo: [NSLocalizedDescriptionKey: "录制时间过短，没有采集到画面"])
        }

        sampleQueue.sync { input.markAsFinished() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            w.finishWriting { c.resume() }
        }
        let status = w.status
        let err = w.error
        reset()
        guard status == .completed else {
            throw err ?? NSError(domain: "ZoomDraw", code: -15,
                                 userInfo: [NSLocalizedDescriptionKey: "视频写入失败"])
        }
        return url
    }

    /// 放弃录制并删除临时文件
    func cancel() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        writer?.cancelWriting()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func reset() {
        writer = nil
        videoInput = nil
        sessionStarted = false
        firstPTS = .invalid
        pausedOffset = .zero
        isPaused = false
        pauseWallClock = 0
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = array.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
        guard let writer, let videoInput, writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            guard !isPaused else { return }
            firstPTS = pts
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        if isPaused { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        let adjusted = CMTimeSubtract(CMTimeSubtract(pts, firstPTS), pausedOffset)
        guard adjusted.isValid, adjusted >= .zero,
              let retimed = Self.retime(sampleBuffer, to: adjusted) else { return }
        if videoInput.append(retimed) { frameCount += 1 }
    }

    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStreamStopped?(error) }
    }

    // MARK: - 工具
    private static func evenValue(_ v: CGFloat) -> Int {
        var n = Int(v.rounded())
        if n % 2 != 0 { n += 1 }
        return max(16, n)
    }

    /// 重设时间戳，使暂停时长不计入视频
    private static func retime(_ sb: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<count {
            timings[i].presentationTimeStamp = pts
            timings[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sb,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
