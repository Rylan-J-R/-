import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - GIF 生成错误

enum GIFGenerationError: LocalizedError {
    case invalidSource
    case frameExtractionFailed
    case encodingFailed
    case noFramesExtracted
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "无法读取视频文件，文件可能已损坏或格式不受支持"
        case .frameExtractionFailed:
            return "视频帧提取失败"
        case .encodingFailed:
            return "GIF 编码失败"
        case .noFramesExtracted:
            return "未能从视频中提取任何帧"
        case .unsupportedFormat:
            return "不支持的文件格式"
        }
    }
}

// MARK: - GIF 生成结果

struct GIFGenerationResult {
    let gifURL: URL
    let frameCount: Int
    let duration: TimeInterval
    let originalSize: Int64
    let gifSize: Int64
}

// MARK: - GIF 生成服务

struct GIFGenerationService {

    // MARK: 支持格式

    static let supportedFormats: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .avi, .movie,
        .gif,
    ]

    // 工具方法：文件大小相关已统一收拢到 FileUtils

    func videoDuration(of url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }

    // MARK: 视频转 GIF

    func generateGIF(
        from videoURL: URL,
        frameRate: Int,
        maxDimension: CGFloat,
        startTime: TimeInterval,
        duration: TimeInterval,
        outputURL: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) throws -> GIFGenerationResult {
        let asset = AVURLAsset(url: videoURL)
        let totalDuration = CMTimeGetSeconds(asset.duration)
        let actualStart = min(startTime, totalDuration)
        let actualDuration = min(duration, totalDuration - actualStart)

        guard actualDuration > 0 else {
            throw GIFGenerationError.invalidSource
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxDimension * 2, height: maxDimension * 2)

        // 计算帧时间
        let frameCount = Int(actualDuration * Double(frameRate))
        guard frameCount > 0 else {
            throw GIFGenerationError.noFramesExtracted
        }

        let frameInterval = actualDuration / Double(frameCount)
        var times: [NSValue] = []
        for i in 0..<frameCount {
            let t = CMTime(seconds: actualStart + Double(i) * frameInterval, preferredTimescale: 600)
            times.append(NSValue(time: t))
        }

        // 提取帧（使用串行队列保护共享状态，消除数据竞争）
        var frames: [CGImage] = []
        var extractionError: Error?

        let syncQueue = DispatchQueue(label: "com.ruitu.gif.frames")
        let semaphore = DispatchSemaphore(value: 0)
        var completedCount = 0

        generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, result, error in
            syncQueue.async {
                if let error = error {
                    extractionError = error
                    semaphore.signal()
                    return
                }

                if result == .succeeded, let image = image {
                    if let resized = Self.resizeImage(image, maxDimension: maxDimension) {
                        frames.append(resized)
                    } else {
                        frames.append(image)
                    }
                }

                completedCount += 1
                let prog = Double(completedCount) / Double(times.count) * 0.8
                progressHandler(prog, "正在提取帧 \(completedCount)/\(times.count)...")

                if completedCount >= times.count {
                    semaphore.signal()
                }
            }
        }

        semaphore.wait()

        if let error = extractionError {
            throw error
        }

        guard !frames.isEmpty else {
            throw GIFGenerationError.noFramesExtracted
        }

        // 编码 GIF
        progressHandler(0.85, "正在编码 GIF...")

        try? FileManager.default.removeItem(at: outputURL)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFGenerationError.encodingFailed
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,  // 无限循环
            ],
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameDelay = 1.0 / Double(frameRate)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
            ],
        ]

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        progressHandler(0.95, "正在写入文件...")

        guard CGImageDestinationFinalize(destination) else {
            throw GIFGenerationError.encodingFailed
        }

        progressHandler(1.0, "GIF 生成完成")

        let originalSize = FileUtils.fileSize(of: videoURL)
        let gifSize = FileUtils.fileSize(of: outputURL)

        return GIFGenerationResult(
            gifURL: outputURL,
            frameCount: frames.count,
            duration: actualDuration,
            originalSize: originalSize,
            gifSize: gifSize
        )
    }

    // MARK: GIF 压缩

    func compressGIF(
        url: URL,
        maxDimension: CGFloat,
        frameSkip: Int,
        outputURL: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) throws -> GIFGenerationResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw GIFGenerationError.invalidSource
        }

        let totalFrames = CGImageSourceGetCount(source)
        guard totalFrames > 0 else {
            throw GIFGenerationError.noFramesExtracted
        }

        let originalSize = FileUtils.fileSize(of: url)

        // 抽帧
        var frames: [CGImage] = []
        let skip = max(1, frameSkip)

        for i in stride(from: 0, to: totalFrames, by: skip) {
            if let image = CGImageSourceCreateImageAtIndex(source, i, nil) {
                if let resized = Self.resizeImage(image, maxDimension: maxDimension) {
                    frames.append(resized)
                } else {
                    frames.append(image)
                }
            }

            let prog = Double(i + 1) / Double(totalFrames) * 0.8
            progressHandler(prog, "正在压缩 GIF 帧 \(i + 1)/\(totalFrames)...")
        }

        guard !frames.isEmpty else {
            throw GIFGenerationError.noFramesExtracted
        }

        // 读取原始帧延迟（逐帧读取，累加被跳过的帧延迟）
        var totalFrameDelay: Double = 0.1
        var sourceFrameDelays: [Double] = []
        for i in 0..<totalFrames {
            let delay: Double
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let d = gifDict[kCGImagePropertyGIFDelayTime] as? Double, d > 0 {
                delay = d
            } else {
                delay = 0.1
            }
            sourceFrameDelays.append(delay)
        }
        // 计算选中帧的总延迟（累加被跳过的帧）
        var sampledDelays: [Double] = []
        for i in stride(from: 0, to: totalFrames, by: skip) {
            let endIndex = min(i + skip, totalFrames)
            let accumulated = sourceFrameDelays[i..<endIndex].reduce(0, +)
            sampledDelays.append(max(accumulated, 0.02))
        }
        totalFrameDelay = sampledDelays.reduce(0, +)

        progressHandler(0.85, "正在编码 GIF...")

        try? FileManager.default.removeItem(at: outputURL)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFGenerationError.encodingFailed
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        for (index, frame) in frames.enumerated() {
            let delay = index < sampledDelays.count ? sampledDelays[index] : 0.1
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(destination, frame, frameProps as CFDictionary)
        }

        progressHandler(0.95, "正在写入文件...")

        guard CGImageDestinationFinalize(destination) else {
            throw GIFGenerationError.encodingFailed
        }

        progressHandler(1.0, "GIF 压缩完成")

        let gifSize = FileUtils.fileSize(of: outputURL)

        return GIFGenerationResult(
            gifURL: outputURL,
            frameCount: frames.count,
            duration: totalFrameDelay,
            originalSize: originalSize,
            gifSize: gifSize
        )
    }

    // MARK: 缩放辅助

    private static func resizeImage(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let scale: CGFloat
        if width > height {
            scale = min(1.0, maxDimension / width)
        } else {
            scale = min(1.0, maxDimension / height)
        }

        guard scale < 1.0 else { return nil }

        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
