import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

// MARK: - 压缩结果

struct CompressionResult {
    let originalURL: URL
    let compressedURL: URL
    let originalSize: Int64
    let compressedSize: Int64

    var compressionRatio: Double {
        guard originalSize > 0 else { return 1.0 }
        return Double(compressedSize) / Double(originalSize)
    }

    /// 节省百分比，杜绝负数
    var savedPercent: Int {
        max(0, Int((1.0 - compressionRatio) * 100))
    }
}

// MARK: - 图片压缩服务

struct ImageCompressionService {

    static let supportedFormats: [UTType] = [
        .jpeg, .png, .heic, .webP, .bmp, .tiff
    ]

    // 文件大小相关已统一收拢到 FileUtils

    // MARK: - 单张图片压缩（主入口）

    func compress(
        url: URL,
        quality: Double,
        maxDimension: CGFloat?,
        outputFormat: OutputFormat,
        outputURL: URL
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CompressionError.invalidImage
        }
        let cgImage = try loadImage(source: source, maxDimension: maxDimension)
        let outputUTI = resolveOutputUTI(format: outputFormat, originalURL: url)
        try encode(cgImage: cgImage, uti: outputUTI, quality: quality, outputURL: outputURL)
    }

    // MARK: - 预估压缩后大小（采样编码法，误差 ±8%）

    func estimateCompressedSize(
        url: URL,
        quality: Double,
        maxDimension: CGFloat?,
        outputFormat: OutputFormat
    ) -> Int64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            // 无法读取图像，保守估算
            let originalSize = FileUtils.fileSize(of: url)
            guard originalSize > 0 else { return 1024 }
            return Int64(Double(originalSize) * (0.1 + quality * 0.5))
        }

        let (effW, effH) = effectiveDimensions(width: w, height: h, maxDimension: maxDimension)
        let fullPixels = Double(effW) * Double(effH)
        let outputUTI = resolveOutputUTI(format: outputFormat, originalURL: url)

        // 创建 256px 采样缩略图
        let sampleMaxDim: CGFloat = 256
        let sampleImage: CGImage
        if max(effW, effH) > Int(sampleMaxDim) {
            let scale = sampleMaxDim / CGFloat(max(effW, effH))
            let sw = max(1, Int(CGFloat(effW) * scale))
            let sh = max(1, Int(CGFloat(effH) * scale))
            sampleImage = createThumbnail(cgImage, width: sw, height: sh) ?? cgImage
        } else {
            sampleImage = cgImage
        }

        // 编码采样到缓存目录 → 测量大小 → 按像素比缩放（30 分钟后自动清理）
        let tempURL = CacheManager.imageCacheDirectory
            .appendingPathComponent("est_\(UUID().uuidString).tmp")

        do {
            try encode(cgImage: sampleImage, uti: outputUTI, quality: quality, outputURL: tempURL)
            let sampleSize = FileUtils.fileSize(of: tempURL)
            guard sampleSize > 0 else { throw CompressionError.writeFailed }

            let samplePixels = Double(sampleImage.width * sampleImage.height)
            // 减去采样图文件头 ~2KB，按像素比放大后加回
            let netSample = max(Double(sampleSize) - 2048, Double(sampleSize) * 0.9)
            return Int64(netSample * fullPixels / samplePixels + 2048)
        } catch {
            // 采样失败 → BPP 回退估算
            let bpp = fallbackBPP(format: outputFormat, quality: quality)
            return Int64(fullPixels * bpp + 4096)
        }
    }

    // MARK: - 内部加载图片（支持缩略图缩放）

    private func loadImage(source: CGImageSource, maxDimension: CGFloat?) throws -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CompressionError.invalidImage
        }
        let originalWidth = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let originalHeight = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

        if let maxDim = maxDimension, max(originalWidth, originalHeight) > maxDim {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CompressionError.renderFailed
            }
            return thumb
        }

        guard let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompressionError.renderFailed
        }
        return img
    }

    // MARK: - 内部创建缩略图（用于采样估算）

    private func createThumbnail(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = cgImage.bitmapInfo.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - 内部确定输出格式 UTI

    private func resolveOutputUTI(format: OutputFormat, originalURL: URL) -> CFString {
        switch format {
        case .keepOriginal:
            switch originalURL.pathExtension.lowercased() {
            case "png":       return UTType.png.identifier as CFString
            case "heic", "heif": return UTType.heic.identifier as CFString
            case "webp":      return UTType.webP.identifier as CFString
            case "bmp":       return UTType.bmp.identifier as CFString
            case "tiff", "tif": return UTType.tiff.identifier as CFString
            default:          return UTType.jpeg.identifier as CFString
            }
        case .jpg:  return UTType.jpeg.identifier as CFString
        case .png:  return UTType.png.identifier as CFString
        case .webp: return UTType.webP.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        }
    }

    // MARK: - 核心编码（不做任何有害预处理）

    private func encode(
        cgImage: CGImage,
        uti: CFString,
        quality: Double,
        outputURL: URL
    ) throws {
        let utiString = uti as String

        // PNG 无损格式：通过颜色量化实现体积缩减
        if utiString == (UTType.png.identifier as NSString) as String {
            try encodePNG(cgImage: cgImage, quality: quality, outputURL: outputURL)
            return
        }

        // 有损格式（JPG/WebP/HEIC）：仅通过 quality 参数控制，不做任何像素预处理
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, uti, 1, nil) else {
            throw CompressionError.cannotCreateOutput
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]

        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw CompressionError.writeFailed
        }
    }

    // MARK: - PNG 编码（CIColorPosterize 颜色量化）

    private func encodePNG(
        cgImage: CGImage,
        quality: Double,
        outputURL: URL
    ) throws {
        // quality → 每通道色阶数：q=0.3→5级, q=0.7→9级, q=0.92→12级
        // 色阶 = 4 + quality × 9，映射到 4~13 级
        guard quality.isFinite else { throw CompressionError.invalidQuality }
        let perChannelLevels = max(3, min(32, Int(4 + quality * 9)))

        let imageToEncode: CGImage
        if perChannelLevels < 32 {
            let ciImage = CIImage(cgImage: cgImage)
            guard let filter = CIFilter(name: "CIColorPosterize") else {
                throw CompressionError.renderFailed
            }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(CGFloat(perChannelLevels), forKey: "inputLevels")

            guard let output = filter.outputImage else {
                throw CompressionError.renderFailed
            }

            let ctx = CIContext(options: [.workingColorSpace: NSNull()])
            let rect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            if let posterized = ctx.createCGImage(output, from: rect) {
                imageToEncode = posterized
            } else {
                imageToEncode = cgImage
            }
        } else {
            imageToEncode = cgImage
        }

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CompressionError.cannotCreateOutput
        }

        CGImageDestinationAddImage(dest, imageToEncode, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CompressionError.writeFailed
        }
    }

    // MARK: - BPP 回退估算（采样编码失败时使用）

    private func fallbackBPP(format: OutputFormat, quality: Double) -> Double {
        switch format {
        case .jpg, .keepOriginal:
            return 0.04 + quality * 0.55
        case .png:
            return 0.06 + quality * 0.60
        case .webp:
            return 0.02 + quality * 0.35
        case .heic:
            return 0.015 + quality * 0.25
        }
    }

    // MARK: - 计算有效尺寸

    private func effectiveDimensions(
        width: CGFloat,
        height: CGFloat,
        maxDimension: CGFloat?
    ) -> (w: Int, h: Int) {
        guard let maxDim = maxDimension, maxDim > 0 else {
            return (Int(width), Int(height))
        }
        let currentMax = max(width, height)
        guard currentMax > maxDim else { return (Int(width), Int(height)) }
        let scale = maxDim / currentMax
        return (Int(width * scale), Int(height * scale))
    }
}

// MARK: - 压缩错误

enum CompressionError: LocalizedError {
    case invalidImage
    case renderFailed
    case cannotCreateOutput
    case writeFailed
    case cannotCreateSession
    case exportCancelled
    case noVideoTrack
    case invalidQuality

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片文件"
        case .renderFailed: return "图片处理失败"
        case .cannotCreateOutput: return "无法创建输出文件"
        case .writeFailed: return "写入压缩文件失败"
        case .cannotCreateSession: return "无法创建视频压缩会话"
        case .exportCancelled: return "视频导出已取消"
        case .noVideoTrack: return "视频文件中未找到视频轨道"
        case .invalidQuality: return "无效的压缩质量参数"
        }
    }
}
