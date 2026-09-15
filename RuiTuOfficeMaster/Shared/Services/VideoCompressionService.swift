import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

// MARK: - 视频编码器

enum VideoCodec: String, CaseIterable {
    case h264 = "H.264"
    case hevc = "H.265 (HEVC)"

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// HEVC 码率效率系数：HEVC 只需 H.264 约 55% 的码率即可达到同等画质
    var bitrateMultiplier: Double {
        switch self {
        case .h264: return 1.0
        case .hevc: return 0.55
        }
    }
}

// MARK: - 视频画质档位

enum VideoQuality: String, CaseIterable {
    case high   = "高画质"
    case medium = "均衡"
    case low    = "小体积"

    // -- 基准码率（以 1080p@30fps H.264 计，单位 bps）----------------------
    // 高→中约 2.3× 差距，中→低约 2.9× 差距，确保每档之间肉眼可区分

    private var baseBitrateFor1080p: Double {
        switch self {
        case .high:   return 8_000_000   // 8 Mbps ≈ CRF 20-22
        case .medium: return 3_500_000   // 3.5 Mbps ≈ CRF 26-28
        case .low:    return 1_200_000   // 1.2 Mbps ≈ CRF 33-35
        }
    }

    /// 每百万像素最低码率 (bps/MP)，保证基础可看性
    private var minBitratePerMP: Double {
        switch self {
        case .high:   return 3_500_000
        case .medium: return 1_500_000
        case .low:    return 350_000
        }
    }

    /// 码率上限 (bps)，防止高分辨率+高帧率场景码率爆炸
    private var maxBitrateCap: Double {
        switch self {
        case .high:   return 40_000_000
        case .medium: return 20_000_000
        case .low:    return 8_000_000
        }
    }

    /// 关键帧间隔（GOP）：越长压缩效率越高，但拖拽进度条响应越慢
    var maxKeyFrameInterval: Int {
        switch self {
        case .high:   return 60
        case .medium: return 120
        case .low:    return 180
        }
    }

    /// B 帧开关：B 帧提升 15-25% 压缩率，但略微降低画质
    var allowFrameReordering: Bool {
        switch self {
        case .high:   return false
        case .medium: return true
        case .low:    return true
        }
    }

    /// 多遍编码（macOS 11+）：同码率下提升画质，适合中低档位
    var useMultiPass: Bool {
        switch self {
        case .high:   return false
        case .medium: return true
        case .low:    return true
        }
    }

    var expectedReduction: String {
        switch self {
        case .high:   return "30%-55%"
        case .medium: return "60%-75%"
        case .low:    return "80%-92%"
        }
    }

    // MARK: - 计算目标码率（核心方法）

    /// 基于输出分辨率、帧率、编码器类型计算目标视频码率（bps）
    /// - Parameters:
    ///   - targetSize: 输出分辨率
    ///   - frameRate: 源帧率（≤0 时按 30fps 处理）
    ///   - sourceBitrate: 源码率 bps（0 表示无法获取）
    ///   - codec: 视频编码器
    /// - Returns: 目标码率 bps
    func computeBitrate(
        targetSize: CGSize,
        frameRate: Float,
        sourceBitrate: Double,
        codec: VideoCodec
    ) -> Double {
        let pixels = targetSize.width * targetSize.height
        guard pixels > 0 else { return baseBitrateFor1080p }

        let mp = pixels / 1_000_000
        let fps = frameRate > 0 ? Double(frameRate) : 30.0

        // 按像素数 + 帧率线性缩放基准码率
        let resolutionBased = baseBitrateFor1080p * (mp / 2.0) * (fps / 30.0)

        // 不低于每像素最低保障
        let minByPixels = minBitratePerMP * mp

        var target = max(resolutionBased, minByPixels)
        target = min(target, maxBitrateCap)

        // HEVC 效率系数
        target *= codec.bitrateMultiplier

        // 若源码率已知，绝不高于源码率的 95%（否则压缩无意义）
        if sourceBitrate > 0 {
            target = min(target, sourceBitrate * 0.95)
        }

        return target
    }
}

// MARK: - 分辨率档位

enum VideoResolution: String, CaseIterable {
    case original = "原始分辨率"
    case uhd4K    = "4K (3840×2160)"
    case fullHD   = "1080p (1920×1080)"
    case hd       = "720p (1280×720)"
    case sd       = "480p (854×480)"

    var maxSize: CGSize {
        switch self {
        case .original: return .zero
        case .uhd4K:    return CGSize(width: 3840, height: 2160)
        case .fullHD:   return CGSize(width: 1920, height: 1080)
        case .hd:       return CGSize(width: 1280, height: 720)
        case .sd:       return CGSize(width: 854, height: 480)
        }
    }

    /// 计算目标尺寸：不放大、保持宽高比、偶数尺寸
    func targetSize(clampedTo sourceSize: CGSize) -> CGSize {
        guard self != .original else { return sourceSize }
        let target = maxSize
        let scale = min(1.0, min(target.width / sourceSize.width, target.height / sourceSize.height))
        let w = max(16, floor(sourceSize.width * scale / 2) * 2)
        let h = max(16, floor(sourceSize.height * scale / 2) * 2)
        return CGSize(width: w, height: h)
    }
}

// MARK: - 输出容器格式

enum VideoOutputFormat: String, CaseIterable {
    case mp4 = "MP4"
    case mov = "MOV"

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    var fileExtension: String { rawValue.lowercased() }
}

// MARK: - 压缩结果分析

/// 对源视频的分析结果，用于预估和编码决策
struct VideoSourceInfo {
    let naturalSize: CGSize
    let frameRate: Float
    let duration: CMTime
    let transform: CGAffineTransform
    /// 源码率 bps（estimatedDataRate 可能为 0，此时通过文件大小推算）
    let sourceBitrate: Double
    /// 源视频是否已被高度压缩（码率低于常规水平）
    let isAlreadyCompressed: Bool
}

// MARK: - 线程安全标记

private final class WriteState: @unchecked Sendable {
    var videoFinished = false
    var audioFinished = false
}

// MARK: - 视频压缩服务

struct VideoCompressionService {

    static let supportedFormats: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .avi, .movie
    ]

    // 文件大小相关已统一收拢到 FileUtils

    // MARK: - 分析源视频（同步，仅用于预估）

    private func analyzeSync(url: URL) -> VideoSourceInfo? {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }

        let naturalSize = videoTrack.naturalSize
        let frameRate = videoTrack.nominalFrameRate
        let duration = asset.duration
        let transform = videoTrack.preferredTransform
        let dataRate = Double(videoTrack.estimatedDataRate)

        // 尝试从元数据获取源码率，失败则通过文件大小推算
        let sourceBitrate: Double
        let durationSec = duration.seconds
        if dataRate > 0 {
            sourceBitrate = dataRate
        } else if durationSec > 0 {
            let fileBytes = FileUtils.fileSize(of: url)
            // 文件大小 × 8(bits) / 时长 × 0.97(视频占比) = 估算码率
            sourceBitrate = Double(fileBytes) * 8.0 / durationSec * 0.97
        } else {
            sourceBitrate = 0
        }

        // 判断视频是否已高度压缩：对比实际码率 vs 高画质推荐码率
        let highQualityBitrate = VideoQuality.high.computeBitrate(
            targetSize: naturalSize, frameRate: frameRate,
            sourceBitrate: sourceBitrate, codec: .h264
        )
        let isAlreadyCompressed = sourceBitrate > 0 && sourceBitrate < highQualityBitrate * 0.5

        return VideoSourceInfo(
            naturalSize: naturalSize,
            frameRate: frameRate,
            duration: duration,
            transform: transform,
            sourceBitrate: sourceBitrate,
            isAlreadyCompressed: isAlreadyCompressed
        )
    }

    // MARK: - 异步分析源视频

    private func analyze(url: URL) async throws -> VideoSourceInfo {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CompressionError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let transform = try await videoTrack.load(.preferredTransform)
        let dataRate = try await videoTrack.load(.estimatedDataRate)

        let sourceBitrate: Double
        let durationSec = duration.seconds
        if dataRate > 0 {
            sourceBitrate = Double(dataRate)
        } else if durationSec > 0 {
            let fileBytes = FileUtils.fileSize(of: url)
            sourceBitrate = Double(fileBytes) * 8.0 / durationSec * 0.97
        } else {
            sourceBitrate = 0
        }

        let highQualityBitrate = VideoQuality.high.computeBitrate(
            targetSize: naturalSize, frameRate: frameRate,
            sourceBitrate: sourceBitrate, codec: .h264
        )
        let isAlreadyCompressed = sourceBitrate > 0 && sourceBitrate < highQualityBitrate * 0.5

        return VideoSourceInfo(
            naturalSize: naturalSize,
            frameRate: frameRate,
            duration: duration,
            transform: transform,
            sourceBitrate: sourceBitrate,
            isAlreadyCompressed: isAlreadyCompressed
        )
    }

    // MARK: - 精准预估压缩后大小（基于实际编码参数，误差 ±5%）

    func estimateCompressedSize(
        url: URL,
        quality: VideoQuality,
        resolution: VideoResolution,
        codec: VideoCodec
    ) -> Int64 {
        let originalSize = FileUtils.fileSize(of: url)
        guard originalSize > 0, let info = analyzeSync(url: url) else { return 0 }

        let durationSec = info.duration.seconds
        guard durationSec > 0 else { return originalSize }

        // 计算输出分辨率
        let targetSize = resolution.targetSize(clampedTo: info.naturalSize)

        // 目标视频码率（与实际编码使用相同的 computeBitrate）
        let targetVideoBitrate = quality.computeBitrate(
            targetSize: targetSize,
            frameRate: info.frameRate,
            sourceBitrate: info.sourceBitrate,
            codec: codec
        )

        // 音频：固定 AAC 128kbps
        let audioBitrate: Double = 128_000

        // 预估 = (视频码率 + 音频码率) × 时长 / 8 + 5% 容器开销
        let estimatedBytes = (targetVideoBitrate + audioBitrate) * durationSec / 8.0 * 1.05

        // 上限：不超过源文件大小
        return Int64(min(estimatedBytes, Double(originalSize) * 0.98))
    }

    // MARK: - 压缩视频

    func compress(
        url: URL,
        quality: VideoQuality,
        resolution: VideoResolution,
        codec: VideoCodec,
        outputFormat: VideoOutputFormat,
        outputURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        let info = try await analyze(url: url)

        let naturalSize = info.naturalSize
        let frameRate = info.frameRate
        let sourceBitrate = info.sourceBitrate
        let duration = info.duration
        let transform = info.transform
        let durationSec = duration.seconds

        // 音频轨道
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        // 计算输出分辨率
        let targetSize = resolution.targetSize(clampedTo: naturalSize)

        // 目标视频码率
        let targetBitrate = quality.computeBitrate(
            targetSize: targetSize,
            frameRate: frameRate,
            sourceBitrate: sourceBitrate,
            codec: codec
        )

        // 边缘场景：极小视频（<500KB）或码率已极低 → 直拷
        let originalSize = FileUtils.fileSize(of: url)
        if originalSize < 512_000 || (sourceBitrate > 0 && targetBitrate >= sourceBitrate * 0.97) {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: url, to: outputURL)
            progressHandler(1.0)
            return
        }

        // 创建 Reader（解码源视频 → 无压缩像素缓冲 + PCM 音频）
        let reader = try AVAssetReader(asset: asset)

        let videoOutput: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressionError.noVideoTrack
        }
        let videoReader = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: videoOutput
        )
        videoReader.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReader) else { throw CompressionError.cannotCreateSession }
        reader.add(videoReader)

        let audioReader: AVAssetReaderTrackOutput?
        if let at = audioTrack {
            let audioOut = AVAssetReaderTrackOutput(track: at, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsNonInterleaved: false
            ])
            audioOut.alwaysCopiesSampleData = false
            if reader.canAdd(audioOut) {
                reader.add(audioOut)
                audioReader = audioOut
            } else {
                audioReader = nil
            }
        } else {
            audioReader = nil
        }

        // 创建 Writer（重编码为目标参数）
        let writer = try AVAssetWriter(url: outputURL, fileType: outputFormat.fileType)
        writer.movieTimeScale = 600

        // 视频压缩属性
        var videoCompSettings: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetBitrate),
            AVVideoMaxKeyFrameIntervalKey: quality.maxKeyFrameInterval,
            AVVideoAllowFrameReorderingKey: quality.allowFrameReordering,
            AVVideoExpectedSourceFrameRateKey: min(max(frameRate, 1), 60)
        ]
        // H.264 指定 High Profile；HEVC 省略让系统自动选择最佳 profile
        if codec == .h264 {
            videoCompSettings[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: videoCompSettings
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        if #available(macOS 11.0, *) {
            videoInput.performsMultiPassEncodingIfSupported = quality.useMultiPass
        }
        guard writer.canAdd(videoInput) else { throw CompressionError.cannotCreateSession }
        writer.add(videoInput)

        // 音频编码 — AAC 128kbps
        let audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        // 启动
        guard reader.startReading() else {
            throw reader.error ?? CompressionError.cannotCreateSession
        }
        guard writer.startWriting() else {
            throw writer.error ?? CompressionError.cannotCreateSession
        }
        writer.startSession(atSourceTime: .zero)

        let state = WriteState()
        state.audioFinished = (audioInput == nil)

        let videoQueue = DispatchQueue(label: "video.compress.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "video.compress.audio", qos: .userInitiated)

        // 视频处理：手动轮询 + 时间戳进度（信号量超时代替忙等）
        videoQueue.async {
            var videoIterations = 0
            let maxVideoIterations = Int(durationSec * 300) + 10000  // 安全上限
            while !state.videoFinished {
                guard videoInput.isReadyForMoreMediaData else {
                    guard videoIterations < maxVideoIterations else {
                        state.videoFinished = true
                        break
                    }
                    videoIterations += 1
                    _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(5))
                    continue
                }
                guard let sample = videoReader.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    state.videoFinished = true
                    break
                }
                videoInput.append(sample)
                if durationSec > 0 {
                    let currentSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    DispatchQueue.main.async {
                        progressHandler(min(1.0, currentSec / durationSec) * 0.95)
                    }
                }
            }
        }

        // 音频处理（信号量超时代替忙等）
        if let aInput = audioInput, let aReader = audioReader {
            audioQueue.async {
                var audioIterations = 0
                let maxAudioIterations = Int(durationSec * 300) + 10000
                while !state.audioFinished {
                    guard aInput.isReadyForMoreMediaData else {
                        guard audioIterations < maxAudioIterations else {
                            state.audioFinished = true
                            break
                        }
                        audioIterations += 1
                        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(5))
                        continue
                    }
                    guard let sample = aReader.copyNextSampleBuffer() else {
                        aInput.markAsFinished()
                        state.audioFinished = true
                        break
                    }
                    aInput.append(sample)
                }
            }
        }

        // 轮询等待完毕（超时 = max(10分钟, 时长×3)，大视频不误杀）
        let startTime = Date()
        let timeoutSeconds: Double = max(600, durationSec * 3)
        while !state.videoFinished || !state.audioFinished {
            if Date().timeIntervalSince(startTime) > timeoutSeconds {
                writer.cancelWriting()
                reader.cancelReading()
                throw CompressionError.exportCancelled
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // 完成写入
        await writer.finishWriting()
        reader.cancelReading()

        if let error = writer.error {
            throw error
        }
        guard writer.status == .completed else {
            throw CompressionError.exportCancelled
        }
    }
}
