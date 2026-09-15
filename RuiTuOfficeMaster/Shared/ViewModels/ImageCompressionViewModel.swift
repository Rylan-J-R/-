import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 压缩档位

enum CompressionLevel: String, CaseIterable {
    case light = "轻度压缩"
    case balanced = "均衡压缩"
    case strong = "强力压缩"
    case custom = "自定义"

    var description: String {
        switch self {
        case .light: return "画质优先"
        case .balanced: return "推荐"
        case .strong: return "体积优先"
        case .custom: return ""
        }
    }

    /// 压缩质量值（严格锁死在用户指定的区间内）
    var qualityValue: Double {
        switch self {
        case .light:    return 0.92   // 区间 88~95，中点
        case .balanced: return 0.72   // 区间 65~80，中点
        case .strong:   return 0.42   // 区间 30~55，中点
        case .custom:   return 0.75
        }
    }

    /// 预期体积缩减范围（用于 UI 提示）
    var expectedReduction: String {
        switch self {
        case .light:    return "10%-30%"
        case .balanced: return "40%-60%"
        case .strong:   return "65%-85%"
        case .custom:   return "—"
        }
    }
}

// MARK: - 尺寸模式

enum SizeMode: String, CaseIterable {
    case aspectRatio = "锁定纵横比"
    case custom = "自定义宽高"
    case maxDimension = "限定最大边长"
}

// MARK: - 输出格式

enum OutputFormat: String, CaseIterable {
    case keepOriginal = "保留原格式"
    case jpg = "JPG"
    case png = "PNG"
    case webp = "WebP"
    case heic = "HEIC"
}

// MARK: - 图片压缩 ViewModel

@Observable
final class ImageCompressionViewModel: @unchecked Sendable {

    // MARK: 图片选择
    var selectedImages: [URL] = []

    // MARK: 压缩参数
    var compressionLevel: CompressionLevel = .balanced
    var quality: Double = 0.72
    var showCustomSlider = false

    // MARK: 尺寸参数
    var sizeMode: SizeMode = .aspectRatio
    var maxDimension: CGFloat = 2048
    var customWidth: String = ""
    var customHeight: String = ""
    var aspectWidth: String = ""
    var aspectHeight: String = ""

    // MARK: 格式参数
    var outputFormat: OutputFormat = .keepOriginal

    // MARK: 预览
    var originalSizes: [URL: Int64] = [:]
    var estimatedSizes: [URL: Int64] = [:]

    // MARK: 处理状态
    var isProcessing = false
    var progress: Double = 0
    var currentFileName = ""

    // MARK: 结果
    var results: [CompressionResult] = []
    var successMessage: String?
    var errorMessage: String?

    private let service = ImageCompressionService()

    // MARK: - 预估竞态控制（取消旧任务，只保留最新）

    private var estimationTask: Task<Void, Never>?

    // MARK: 计算属性

    var effectiveQuality: Double {
        if compressionLevel == .custom { return quality }
        return compressionLevel.qualityValue
    }

    var effectiveMaxDimension: CGFloat? {
        switch sizeMode {
        case .maxDimension:
            return maxDimension
        case .aspectRatio:
            let w = Double(aspectWidth) ?? 0
            let h = Double(aspectHeight) ?? 0
            let maxDim = max(w, h)
            return maxDim > 0 ? CGFloat(maxDim) : nil
        case .custom:
            let w = Double(customWidth) ?? 0
            let h = Double(customHeight) ?? 0
            let maxDim = max(w, h)
            return maxDim > 0 ? CGFloat(maxDim) : nil
        }
    }

    var aspectRatio: CGFloat {
        guard let firstURL = selectedImages.first else { return 1.0 }
        guard let source = CGImageSourceCreateWithURL(firstURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              height > 0 else { return 1.0 }
        return width / height
    }

    var imageCountText: String {
        "已选择 \(selectedImages.count) 张图片"
    }

    var originalTotalSizeText: String {
        let total = selectedImages.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    var estimatedSizeText: String {
        FileUtils.formatSize(estimatedTotalSize)
    }

    var estimatedSavedPercent: Int {
        let totalOriginal = selectedImages.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        guard totalOriginal > 0 else { return 0 }
        return max(0, Int((1 - Double(estimatedTotalSize) / Double(totalOriginal)) * 100))
    }

    /// 预估压缩后总大小
    private var estimatedTotalSize: Int64 {
        selectedImages.reduce(0) { $0 + (estimatedSizes[$1] ?? 0) }
    }

    var qualityPercent: Int {
        Int(effectiveQuality * 100)
    }

    var canExecute: Bool {
        guard !selectedImages.isEmpty, !isProcessing else { return false }
        switch sizeMode {
        case .custom:
            return (Int(customWidth) ?? 0) > 0 && (Int(customHeight) ?? 0) > 0
        case .aspectRatio:
            let w = Int(aspectWidth) ?? 0
            let h = Int(aspectHeight) ?? 0
            return w > 0 || h > 0
        case .maxDimension:
            return true
        }
    }

    var hasLargeFiles: Bool {
        selectedImages.contains { (originalSizes[$0] ?? 0) > 50_000_000 }
    }

    var largeFileWarning: String? {
        guard hasLargeFiles else { return nil }
        let count = selectedImages.filter { (originalSizes[$0] ?? 0) > 50_000_000 }.count
        return "已选择 \(count) 张超大图片（>50MB），压缩可能需要较长时间"
    }

    /// 小文件 / 无压缩空间提示
    var smallFileNote: String? {
        let tiny = selectedImages.filter { (originalSizes[$0] ?? 0) < 10_240 && (originalSizes[$0] ?? 0) > 0 }
        if !tiny.isEmpty {
            return "已选择 \(tiny.count) 张极小图片（<10KB），继续压缩空间有限"
        }
        // 预估节省接近 0 → 提示无压缩空间
        let totalOrig = selectedImages.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        let totalEst = estimatedTotalSize
        if totalOrig > 0 && totalEst > 0 && Double(totalEst) >= Double(totalOrig) * 0.95 {
            return "原图已高度精简，可压缩空间极小"
        }
        return nil
    }

    // MARK: 压缩档位切换

    func selectCompressionLevel(_ level: CompressionLevel) {
        compressionLevel = level
        showCustomSlider = level == .custom
        if level != .custom {
            quality = level.qualityValue
        }
        refreshEstimates()
    }

    // MARK: 等比锁定宽高联动

    func syncHeightFromWidth() {
        guard let w = Double(aspectWidth), w > 0 else { return }
        let ratio = aspectRatio
        let targetH = Int(w / ratio)
        let currentH = Int(aspectHeight) ?? 0
        guard abs(currentH - targetH) > 2 else { return }
        aspectHeight = "\(targetH)"
        refreshEstimates()
    }

    func syncWidthFromHeight() {
        guard let h = Double(aspectHeight), h > 0 else { return }
        let ratio = aspectRatio
        let targetW = Int(h * ratio)
        let currentW = Int(aspectWidth) ?? 0
        guard abs(currentW - targetW) > 2 else { return }
        aspectWidth = "\(targetW)"
        refreshEstimates()
    }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ImageCompressionService.supportedFormats

        if panel.runModal() == .OK {
            addImages(from: panel.urls)
        }
    }
#endif

    // MARK: 管理已选图片

    func removeImage(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedImages.firstIndex(of: url) else { return }
        selectedImages.remove(at: index)
        originalSizes.removeValue(forKey: url)
        estimatedSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
    }

    func moveImages(from source: IndexSet, to destination: Int) {
        selectedImages.move(fromOffsets: source, toOffset: destination)
        results = []
        clearMessages()
    }

    // MARK: 拖拽添加图片

    func addImages(from urls: [URL]) {
        guard !isProcessing else { return }
        let imageURLs = urls.filter { url in
            guard url.isFileURL, !selectedImages.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return ImageCompressionService.supportedFormats.contains(type)
        }
        selectedImages.append(contentsOf: imageURLs)
        loadOriginalSizes()
        refreshEstimates()
        clearMessages()
    }

    // MARK: 预加载文件大小

    private func loadOriginalSizes() {
        for url in selectedImages {
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        if sizeMode == .aspectRatio, let firstURL = selectedImages.first,
           let source = CGImageSourceCreateWithURL(firstURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            aspectWidth = "\(w)"
            aspectHeight = "\(h)"
        }
    }

    // MARK: 刷新预估（Task 自动取消旧请求，保证滑块拖动顺滑）

    func refreshEstimates() {
        guard !selectedImages.isEmpty else { return }

        estimationTask?.cancel()
        estimationTask = Task { [weak self] in
            guard let self else { return }

            let q = self.effectiveQuality
            let maxDim = self.effectiveMaxDimension
            let fmt = self.outputFormat
            let urls = self.selectedImages

            // 采样编码在后台执行，避免阻塞 UI
            let svc = ImageCompressionService()
            var newEstimates: [URL: Int64] = [:]

            for url in urls {
                guard !Task.isCancelled else { return }
                newEstimates[url] = svc.estimateCompressedSize(
                    url: url, quality: q, maxDimension: maxDim, outputFormat: fmt
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.estimatedSizes = newEstimates
            }
        }
    }

    // MARK: 执行压缩

    func executeCompression() {
        guard canExecute else { return }

        isProcessing = true
        progress = 0
        results = []
        clearMessages()

        let images = selectedImages
        let q = effectiveQuality
        let maxDim = effectiveMaxDimension
        let fmt = outputFormat
        let sizes = originalSizes

        Task { [weak self] in
            guard let self else { return }
            let svc = ImageCompressionService()
            var compressionResults: [CompressionResult] = []
            var errors: [String] = []

            for url in images {
                guard !Task.isCancelled else { break }

                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let targetExt: String
                switch fmt {
                case .keepOriginal: targetExt = url.pathExtension
                case .jpg:  targetExt = "jpg"
                case .png:  targetExt = "png"
                case .webp: targetExt = "webp"
                case .heic: targetExt = "heic"
                }
                let compressedName = "\(originalName)_compressed.\(targetExt)"
                let outputDir = FileManager.default.temporaryDirectory
                let outputURL = outputDir.appendingPathComponent(compressedName)
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    try svc.compress(
                        url: url, quality: q, maxDimension: maxDim,
                        outputFormat: fmt, outputURL: outputURL
                    )
                    let originalSize = sizes[url] ?? 0
                    var compressedSize = FileUtils.fileSize(of: outputURL)

                    // 兜底：压缩后体积 ≥ 原图 → 自动降级重压
                    if compressedSize >= originalSize && originalSize > 0 {
                        let retryURL = outputDir.appendingPathComponent("\(originalName)_retry.\(targetExt)")
                        try? FileManager.default.removeItem(at: retryURL)

                        // 第一轮：质量 × 0.5
                        do {
                            try svc.compress(
                                url: url, quality: q * 0.5, maxDimension: maxDim,
                                outputFormat: fmt, outputURL: retryURL
                            )
                            let retrySize = FileUtils.fileSize(of: retryURL)
                            if retrySize < compressedSize {
                                try? FileManager.default.removeItem(at: outputURL)
                                try? FileManager.default.moveItem(at: retryURL, to: outputURL)
                                compressedSize = retrySize
                            } else {
                                try? FileManager.default.removeItem(at: retryURL)
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: retryURL)
                        }

                        // 第二轮：质量 × 0.2 极限兜底
                        if compressedSize >= originalSize {
                            let finalURL = outputDir.appendingPathComponent("\(originalName)_final.\(targetExt)")
                            try? FileManager.default.removeItem(at: finalURL)
                            do {
                                try svc.compress(
                                    url: url, quality: 0.2, maxDimension: maxDim,
                                    outputFormat: fmt, outputURL: finalURL
                                )
                                let finalSize = FileUtils.fileSize(of: finalURL)
                                if finalSize < compressedSize {
                                    try? FileManager.default.removeItem(at: outputURL)
                                    try? FileManager.default.moveItem(at: finalURL, to: outputURL)
                                    compressedSize = finalSize
                                } else {
                                    try? FileManager.default.removeItem(at: finalURL)
                                }
                            } catch {
                                try? FileManager.default.removeItem(at: finalURL)
                            }
                        }

                        // 三轮仍无效 → 保留原始文件（savedPercent = 0）
                        if compressedSize >= originalSize {
                            try? FileManager.default.removeItem(at: outputURL)
                            try? FileManager.default.copyItem(at: url, to: outputURL)
                            compressedSize = originalSize
                        }
                    }

                    compressionResults.append(CompressionResult(
                        originalURL: url,
                        compressedURL: outputURL,
                        originalSize: originalSize,
                        compressedSize: compressedSize
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let done = Double(compressionResults.count + errors.count)
                let total = Double(images.count)
                let name = url.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.progress = done / total
                    self?.currentFileName = name
                }
            }

            let finalResults = compressionResults
            let finalErrors = errors

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = finalResults

                if finalErrors.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.compressedSize }
                    let savedPct = totalIn > 0 ? Int((1 - Double(totalOut) / Double(totalIn)) * 100) : 0
                    if savedPct <= 0 && totalIn > 0 {
                        self.successMessage = "图片已是极致精简状态，未进一步压缩"
                    } else {
                        self.successMessage = "成功压缩 \(finalResults.count) 张图片，节省 \(savedPct)% 空间"
                    }
                } else if finalResults.isEmpty {
                    self.errorMessage = finalErrors.joined(separator: "\n")
                } else {
                    self.successMessage = "成功压缩 \(finalResults.count) 张图片，\(finalErrors.count) 张失败"
                }

                // 历史记录
                if !finalResults.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.compressedSize }
                    let savedPct = totalIn > 0 ? Int((1 - Double(totalOut) / Double(totalIn)) * 100) : 0
                    HistoryService().addRecord(
                        toolName: "图片处理",
                        operationType: "批量压缩",
                        fileCount: finalResults.count,
                        inputFileNames: finalResults.map { $0.originalURL.lastPathComponent },
                        status: finalErrors.isEmpty ? "成功" : "部分成功",
                        inputSize: totalIn,
                        outputSize: totalOut,
                        descriptionText: "压缩 \(finalResults.count) 张图片，节省 \(max(0, savedPct))% 空间"
                    )
                }
            }
        }
    }

    // MARK: 保存压缩后的图片到指定目录

#if os(macOS)
    @MainActor
    func saveResults() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "保存到这里"

        if panel.runModal() == .OK, let dir = panel.url {
            var savedCount = 0
            var saveErrors: [String] = []
            for result in results {
                let dest = dir.appendingPathComponent(result.compressedURL.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: result.compressedURL, to: dest)
                    savedCount += 1
                } catch {
                    saveErrors.append("\(result.compressedURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if saveErrors.isEmpty {
                successMessage = "已保存 \(savedCount) 个文件到 \(dir.lastPathComponent)"
            } else {
                successMessage = "保存完成：\(savedCount) 个成功，\(saveErrors.count) 个失败"
                errorMessage = saveErrors.joined(separator: "\n")
            }
        }
    }
#endif

    // MARK: 辅助

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }
}
