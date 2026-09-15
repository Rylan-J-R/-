import Foundation
import CoreImage
import ImageIO
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers
import Accelerate

// MARK: - 证件照背景色

enum IDPhotoBackground: String, CaseIterable {
    case white
    case red
    case blue

    var name: String {
        switch self {
        case .white: return "纯白色"
        case .red:   return "标准红"
        case .blue:  return "标准蓝"
        }
    }

    /// 标准证件照背景色（0~1 浮点）
    var ciColor: CIColor {
        switch self {
        case .white: return CIColor(red: 1.0, green: 1.0, blue: 1.0)
        case .red:   return CIColor(red: 0.82, green: 0.09, blue: 0.11)
        case .blue:  return CIColor(red: 0.26, green: 0.56, blue: 0.85)
        }
    }

    /// 返回 0~255 整型分量
    var rgbBytes: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .white: return (255, 255, 255)
        case .red:   return (209, 23, 28)
        case .blue:  return (66, 143, 217)
        }
    }

    var displayColor: CGColor {
        CGColor(red: ciColor.red, green: ciColor.green, blue: ciColor.blue, alpha: 1.0)
    }
}

// MARK: - 证件照尺寸

enum IDPhotoSize: String, CaseIterable {
    case oneInch
    case twoInch

    var name: String {
        switch self {
        case .oneInch: return "一寸（25×35mm）"
        case .twoInch: return "二寸（35×49mm）"
        }
    }

    /// 宽高比（宽/高）
    var aspectRatio: CGFloat {
        switch self {
        case .oneInch: return 25.0 / 35.0
        case .twoInch: return 35.0 / 49.0
        }
    }

    /// 标准像素尺寸（300 DPI 参考值，仅展示用）
    var referencePixelSize: CGSize {
        switch self {
        case .oneInch: return CGSize(width: 295, height: 413)
        case .twoInch: return CGSize(width: 413, height: 579)
        }
    }
}


/// 预计算的背景遮罩，可缓存复用
/// 底色切换时无需重新计算，直接应用即可（毫秒级）
struct BackgroundMask {
    let width: Int
    let height: Int
    /// 每个像素的 alpha 值：0=纯背景（将被替换），255=纯前景（100%保留），中间值=羽化过渡
    let alpha: [UInt8]
}

// MARK: - IDPhotoService

struct IDPhotoService {

    // MARK: 支持的格式

    static let supportedFormats: [UTType] = [
        .jpeg, .png, .heic, .bmp, .tiff
    ]

    // MARK: 图片加载

    func loadImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw IDPhotoError.invalidImage
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw IDPhotoError.invalidImage
        }
        return image
    }

    // MARK: 背景色检测

    /// 从图片四边均匀采样，检测当前背景色（返回 0~255 整型）
    func detectBackgroundColor(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = image.width
        let height = image.height

        // 将图片绘制到标准 BGRA8 上下文中，确保像素格式一致
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return (255, 255, 255)
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            return (255, 255, 255)
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else {
            return (255, 255, 255)
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        let step = 5
        let bytesPerRow = ctx.bytesPerRow

        var totalR: UInt64 = 0
        var totalG: UInt64 = 0
        var totalB: UInt64 = 0
        var count: UInt64 = 0

        // 采样四边：上、下、左、右各取一条窄带
        let edgeWidth = min(width, 20)

        // 上边
        for y in 0..<min(edgeWidth, height) {
            for x in stride(from: 0, to: width, by: step) {
                let off = y * bytesPerRow + x * 4
                totalB += UInt64(pixels[off])
                totalG += UInt64(pixels[off + 1])
                totalR += UInt64(pixels[off + 2])
                count += 1
            }
        }

        // 下边
        for y in max(0, height - edgeWidth)..<height {
            for x in stride(from: 0, to: width, by: step) {
                let off = y * bytesPerRow + x * 4
                totalB += UInt64(pixels[off])
                totalG += UInt64(pixels[off + 1])
                totalR += UInt64(pixels[off + 2])
                count += 1
            }
        }

        // 左边（避开已采样的上下角）
        for y in stride(from: edgeWidth, to: height - edgeWidth, by: step) {
            for x in 0..<min(edgeWidth, width) {
                let off = y * bytesPerRow + x * 4
                totalB += UInt64(pixels[off])
                totalG += UInt64(pixels[off + 1])
                totalR += UInt64(pixels[off + 2])
                count += 1
            }
        }

        // 右边（避开已采样的上下角）
        for y in stride(from: edgeWidth, to: height - edgeWidth, by: step) {
            for x in max(0, width - edgeWidth)..<width {
                let off = y * bytesPerRow + x * 4
                totalB += UInt64(pixels[off])
                totalG += UInt64(pixels[off + 1])
                totalR += UInt64(pixels[off + 2])
                count += 1
            }
        }

        guard count > 0 else { return (255, 255, 255) }

        return (
            r: UInt8(totalR / count),
            g: UInt8(totalG / count),
            b: UInt8(totalB / count)
        )
    }

    // MARK: 背景遮罩预计算（可缓存，供底色快速切换）

    /// 预计算背景 alpha 遮罩（昂贵操作，仅图片变更或容差变更时执行一次）
    ///
    /// **算法铁则**：
    /// 1. 逐行背景建模 → 每行取左右边缘平均色作为该行背景参考色
    /// 2. 逐像素对比该行背景色计算曼哈顿距离 → 泛洪填充"连通到四边"的背景区域 → `isBg`
    /// 3. 对 `isBg` 做 3 像素安全侵蚀 → `isDeepBg`（绝不触碰人物）
    /// 4. 侵蚀掉的 3 像素环 → 羽化过渡带（纯背景侧，向前景渐变）
    /// 5. 人物区域（`!isBg`）→ alpha=255，100% 锁定原图像素
    ///
    /// 深色衣服在蓝色/白色背景行必然超出容差，不会被误判为背景。
    func computeMask(image: CGImage, tolerance: Int = 70) throws -> BackgroundMask {
        let width = image.width
        let height = image.height
        let pixelCount = width * height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw IDPhotoError.backgroundReplacementFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            throw IDPhotoError.backgroundReplacementFailed
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else {
            throw IDPhotoError.backgroundReplacementFailed
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let rowBytes = ctx.bytesPerRow
        let threshold = Int32(tolerance)

        // —— 步骤 1：逐行背景建模（每行取左右边缘平均色） ——
        // 背景可能是纵向渐变（如顶蓝底黑），全局色域会误伤深色衣服
        // 逐行对比该行边缘颜色，深色衣服在蓝色行必然超出容差
        let edgeWidth = min(20, width / 10)
        var rowBgR = [UInt8](repeating: 0, count: height)
        var rowBgG = [UInt8](repeating: 0, count: height)
        var rowBgB = [UInt8](repeating: 0, count: height)

        for y in 0..<height {
            var totalR: UInt64 = 0, totalG: UInt64 = 0, totalB: UInt64 = 0, count: UInt64 = 0
            let rowOff = y * rowBytes
            for x in 0..<edgeWidth {
                let off = rowOff + x * 4
                totalR += UInt64(pixels[off + 2]); totalG += UInt64(pixels[off + 1]); totalB += UInt64(pixels[off])
                count += 1
            }
            for x in max(0, width - edgeWidth)..<width {
                let off = rowOff + x * 4
                totalR += UInt64(pixels[off + 2]); totalG += UInt64(pixels[off + 1]); totalB += UInt64(pixels[off])
                count += 1
            }
            if count > 0 {
                rowBgR[y] = UInt8(totalR / count)
                rowBgG[y] = UInt8(totalG / count)
                rowBgB[y] = UInt8(totalB / count)
            }
        }

        // —— 步骤 2：逐像素对比该行背景色 + 距边缘距离惩罚 ——
        // 距边缘越远的像素，越不可能是背景（防止 BFS 从底部暗角渗入深色衣服/鞋子）
        var bgDistance = [Int32](repeating: Int32.max, count: pixelCount)
        let maxDim = Double(max(width, height))
        let toleranceD = Double(threshold)
        for y in 0..<height {
            let rowOff = y * rowBytes
            let bgR = Int32(rowBgR[y]), bgG = Int32(rowBgG[y]), bgB = Int32(rowBgB[y])
            for x in 0..<width {
                let i = y * width + x
                let off = rowOff + x * 4
                let r = Int32(pixels[off + 2])
                let g = Int32(pixels[off + 1])
                let b = Int32(pixels[off])
                let colorDist = abs(r - bgR) + abs(g - bgG) + abs(b - bgB)

                // 距边缘惩罚：越靠近图像中心，越需要严格匹配
                let edgeDist = Double(min(min(x, width - 1 - x), min(y, height - 1 - y)))
                let penalty = Int32(edgeDist / maxDim * toleranceD * 5.0)

                bgDistance[i] = colorDist + penalty
            }
        }

        // —— 步骤 3：泛洪填充（连通域） ——
        // 只有"颜色接近该行背景 且 连通到图像四边"的像素才是背景
        var isBg = [Bool](repeating: false, count: pixelCount)
        var queue = [Int]()
        queue.reserveCapacity(pixelCount / 4)
        var head = 0

        // 从四边播种
        for x in 0..<width {
            if bgDistance[x] <= threshold { isBg[x] = true; queue.append(x) }
            if height > 1 {
                let iBottom = (height - 1) * width + x
                if bgDistance[iBottom] <= threshold { isBg[iBottom] = true; queue.append(iBottom) }
            }
        }
        for y in 1..<(height - 1) {
            let iLeft = y * width
            if bgDistance[iLeft] <= threshold { isBg[iLeft] = true; queue.append(iLeft) }
            if width > 1 {
                let iRight = y * width + (width - 1)
                if bgDistance[iRight] <= threshold { isBg[iRight] = true; queue.append(iRight) }
            }
        }

        // BFS 传播
        while head < queue.count {
            let idx = queue[head]; head += 1
            let x = idx % width, y = idx / width
            if y > 0 {
                let ni = idx - width
                if !isBg[ni] && bgDistance[ni] <= threshold { isBg[ni] = true; queue.append(ni) }
            }
            if y < height - 1 {
                let ni = idx + width
                if !isBg[ni] && bgDistance[ni] <= threshold { isBg[ni] = true; queue.append(ni) }
            }
            if x > 0 {
                let ni = idx - 1
                if !isBg[ni] && bgDistance[ni] <= threshold { isBg[ni] = true; queue.append(ni) }
            }
            if x < width - 1 {
                let ni = idx + 1
                if !isBg[ni] && bgDistance[ni] <= threshold { isBg[ni] = true; queue.append(ni) }
            }
        }

        // —— 步骤 4：安全侵蚀（3 像素） ——
        // 将背景遮罩向内收缩 3 像素，创建"深背景"区域
        // 侵蚀掉的 3 像素环 → 羽化过渡带（纯在背景侧，绝不碰人物）
        let safetyMargin = 3
        var isDeepBg = isBg
        for _ in 0..<safetyMargin {
            var next = isDeepBg
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard isDeepBg[i] else { continue }
                    // 8 邻域中有人物像素 → 侵蚀掉
                    var touchesPerson = false
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dy == 0 && dx == 0 { continue }
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            if !isBg[ny * width + nx] { touchesPerson = true; break }
                        }
                        if touchesPerson { break }
                    }
                    if touchesPerson { next[i] = false }
                }
            }
            isDeepBg = next
        }

        // —— 步骤 5：计算 alpha ——
        // isDeepBg → alpha=0（深背景，完全替换为目标色）
        // isBg 但非 isDeepBg → 羽化过渡带（5×5 窗口前景占比）
        // !isBg → alpha=1（人物主体，100% 锁定，永远不动）
        var alphaFloat = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            if isDeepBg[i] {
                alphaFloat[i] = 0.0
            } else if isBg[i] {
                // 过渡带像素：基于 5×5 窗口内人物像素占比
                let y = i / width, x = i % width
                var fgCount = 0, total = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        if !isBg[ny * width + nx] { fgCount += 1 }
                        total += 1
                    }
                }
                alphaFloat[i] = Float(fgCount) / Float(total)
            } else {
                alphaFloat[i] = 1.0
            }
        }

        // —— 步骤 6：转为 UInt8 存储（12MP 图片仅 ~12MB） ——
        let alphaBytes = alphaFloat.map { val -> UInt8 in
            let scaled = (val * 255.0).rounded()
            return scaled <= 0 ? 0 : (scaled >= 255 ? 255 : UInt8(scaled))
        }

        return BackgroundMask(width: width, height: height, alpha: alphaBytes)
    }

    /// 使用预计算遮罩 + 新底色快速合成（毫秒级，供底色切换时调用）
    ///
    /// 此方法仅执行最终 alpha 混合步骤，跳过所有昂贵的 mask 计算。
    /// 人物主体像素（alpha=255）100% 保留，仅背景区域替换颜色。
    func applyMask(_ mask: BackgroundMask, targetColor: IDPhotoBackground, to image: CGImage) throws -> CGImage {
        let width = mask.width
        let height = mask.height
        let target = targetColor.rgbBytes

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw IDPhotoError.backgroundReplacementFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            throw IDPhotoError.backgroundReplacementFailed
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else {
            throw IDPhotoError.backgroundReplacementFailed
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let rowBytes = ctx.bytesPerRow
        let newR = Float(target.r), newG = Float(target.g), newB = Float(target.b)
        let alpha = mask.alpha

        for y in 0..<height {
            let rowOff = y * rowBytes
            for x in 0..<width {
                let i = y * width + x
                let a = Float(alpha[i]) / 255.0

                if a <= 0.001 {
                    let off = rowOff + x * 4
                    pixels[off]     = target.b
                    pixels[off + 1] = target.g
                    pixels[off + 2] = target.r
                } else if a < 0.999 {
                    let off = rowOff + x * 4
                    let origB = Float(pixels[off])
                    let origG = Float(pixels[off + 1])
                    let origR = Float(pixels[off + 2])
                    pixels[off]     = UInt8((a * origB + (1 - a) * newB).rounded())
                    pixels[off + 1] = UInt8((a * origG + (1 - a) * newG).rounded())
                    pixels[off + 2] = UInt8((a * origR + (1 - a) * newR).rounded())
                }
            }
        }

        guard let result = ctx.makeImage() else {
            throw IDPhotoError.backgroundReplacementFailed
        }
        return result
    }

    // MARK: 背景替换（一体式，供最终处理使用）

    /// 纯背景色替换：computeMask + applyMask 一步完成（包含安全侵蚀 + 羽化）
    func replaceBackground(
        image: CGImage,
        targetColor: IDPhotoBackground,
        tolerance: Int = 70
    ) throws -> CGImage {
        let mask = try computeMask(image: image, tolerance: tolerance)
        return try applyMask(mask, targetColor: targetColor, to: image)
    }

    // MARK: 比例裁切

    /// 按目标宽高比裁切图片，支持垂直偏移（-1 到 1，0 居中）
    func cropToRatio(image: CGImage, ratio: CGFloat, offsetY: CGFloat = 0) throws -> CGImage {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let imageRatio = imageWidth / imageHeight

        var cropWidth: CGFloat
        var cropHeight: CGFloat

        if imageRatio > ratio {
            cropHeight = imageHeight
            cropWidth = cropHeight * ratio
        } else {
            cropWidth = imageWidth
            cropHeight = cropWidth / ratio
        }

        let originX = (imageWidth - cropWidth) / 2
        let maxOffsetY = (imageHeight - cropHeight) / 2
        let originY = maxOffsetY + offsetY * maxOffsetY

        let cropRect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
        guard let cropped = image.cropping(to: cropRect) else {
            throw IDPhotoError.cropFailed
        }
        return cropped
    }

    // MARK: KB 精准压缩

    /// 二分搜索逼近目标 KB，同时保底画质不低于 qualityFloor
    func compressToTargetSize(
        image: CGImage,
        targetKB: Int,
        qualityFloor: CGFloat = 0.55,
        maxIterations: Int = 14
    ) throws -> Data {
        let targetBytes = targetKB * 1024

        // 先试最高画质
        if let best = encodeJPEG(image: image, quality: 0.98), best.count <= targetBytes {
            return best
        }

        // 二分搜索
        var low: CGFloat = qualityFloor
        var high: CGFloat = 0.98
        var bestData: Data?

        for _ in 0..<maxIterations {
            let quality = (low + high) / 2
            guard let data = encodeJPEG(image: image, quality: quality) else { break }

            if data.count <= targetBytes {
                bestData = data
                low = quality  // 尝试更高画质
            } else {
                high = quality
            }

            if high - low < 0.005 { break }
        }

        // 退路：用最低保底画质
        if bestData == nil {
            bestData = encodeJPEG(image: image, quality: qualityFloor)
        }

        guard let result = bestData else {
            throw IDPhotoError.compressionFailed
        }
        return result
    }

    // MARK: 导出

    func exportImage(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IDPhotoError.exportFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IDPhotoError.exportFailed
        }
    }

    func exportData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    // MARK: 预览

#if os(macOS)
    func makePreview(from image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
#endif

    // MARK: JPEG 编码

    private func encodeJPEG(image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // 文件大小相关已统一收拢到 FileUtils
}

// MARK: - 错误

enum IDPhotoError: LocalizedError {
    case invalidImage
    case backgroundReplacementFailed
    case cropFailed
    case compressionFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片文件，请确认图片格式正确"
        case .backgroundReplacementFailed: return "背景替换失败，请重试"
        case .cropFailed: return "图片裁切失败"
        case .compressionFailed: return "图片压缩失败"
        case .exportFailed: return "导出失败，请检查磁盘空间"
        }
    }
}
