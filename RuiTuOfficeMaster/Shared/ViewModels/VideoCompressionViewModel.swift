import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 视频压缩结果

struct VideoCompressionItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let compressedURL: URL
    let originalSize: Int64
    let compressedSize: Int64

    /// 节省百分比，杜绝负数
    var savedPercent: Int {
        guard originalSize > 0 else { return 0 }
        return max(0, Int((1 - Double(compressedSize) / Double(originalSize)) * 100))
    }
}

// MARK: - 视频压缩 ViewModel

@Observable
final class VideoCompressionViewModel: @unchecked Sendable {

    // MARK: 视频选择
    var selectedVideos: [URL] = []
    var originalSizes: [URL: Int64] = [:]

    // MARK: 压缩参数
    var quality: VideoQuality = .medium
    var resolution: VideoResolution = .original
    var codec: VideoCodec = .h264
    var outputFormat: VideoOutputFormat = .mp4

    // MARK: 预估
    var estimatedSizes: [URL: Int64] = [:]

    // MARK: 处理状态
    var isProcessing = false
    var progress: Double = 0
    var currentFileName = ""

    // MARK: 结果
    var results: [VideoCompressionItem] = []
    var successMessage: String?
    var errorMessage: String?

    private let service = VideoCompressionService()
    private var estimationTask: Task<Void, Never>?

    // MARK: 计算属性

    var videoCountText: String {
        "已选择 \(selectedVideos.count) 个视频"
    }

    var originalTotalSizeText: String {
        let total = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    /// 预估压缩后总大小
    var estimatedSizeText: String {
        FileUtils.formatSize(estimatedTotalSize)
    }

    /// 预估节省百分比
    var estimatedSavedPercent: Int {
        let totalOriginal = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        guard totalOriginal > 0 else { return 0 }
        return max(0, Int((1 - Double(estimatedTotalSize) / Double(totalOriginal)) * 100))
    }

    private var estimatedTotalSize: Int64 {
        selectedVideos.reduce(0) { $0 + (estimatedSizes[$1] ?? 0) }
    }

    /// 单个视频预估压缩后大小文本
    func estimatedSizeText(for url: URL) -> String {
        FileUtils.formatSize(estimatedSizes[url] ?? 0)
    }

    /// 单个视频预估节省百分比
    func estimatedSavedPercent(for url: URL) -> Int {
        let orig = originalSizes[url] ?? 0
        let est = estimatedSizes[url] ?? 0
        guard orig > 0, est > 0 else { return 0 }
        return max(0, Int((1 - Double(est) / Double(orig)) * 100))
    }

    /// 小文件 / 大文件 / 无压缩空间提示
    var smallFileNote: String? {
        let tiny = selectedVideos.filter { (originalSizes[$0] ?? 0) < 1_048_576 && (originalSizes[$0] ?? 0) > 0 }
        if !tiny.isEmpty {
            return "已选择 \(tiny.count) 个极小视频（<1MB），继续压缩空间有限"
        }
        let totalOrig = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        let totalEst = estimatedTotalSize
        if totalOrig > 0 && totalEst > 0 && Double(totalEst) >= Double(totalOrig) * 0.95 {
            return "原视频已高度压缩，可压缩空间极小"
        }
        if totalOrig > 500_000_000 {
            let note = codec == .hevc ? "预计耗时较长（HEVC 编码约 2-4 倍视频时长）" : "预计耗时较长（约 0.5-2 倍视频时长）"
            return "总文件较大（>500MB），\(note)，请耐心等待"
        }
        return nil
    }

    var canExecute: Bool {
        !selectedVideos.isEmpty && !isProcessing
    }

    // MARK: 视频选择

#if os(macOS)
    @MainActor
    func selectVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = VideoCompressionService.supportedFormats

        if panel.runModal() == .OK {
            addVideos(from: panel.urls)
        }
    }
#endif

    func addVideos(from urls: [URL]) {
        guard !isProcessing else { return }
        let newURLs = urls.filter { url in
            guard url.isFileURL, !selectedVideos.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return VideoCompressionService.supportedFormats.contains(type)
        }
        selectedVideos.append(contentsOf: newURLs)
        for url in newURLs {
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        refreshEstimates()
        clearMessages()
    }

    // MARK: 管理已选视频

    func removeVideo(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedVideos.firstIndex(of: url) else { return }
        selectedVideos.remove(at: index)
        originalSizes.removeValue(forKey: url)
        estimatedSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
    }

    // MARK: 刷新预估（基于目标码率×时长，误差 ±5%）

    func refreshEstimates() {
        guard !selectedVideos.isEmpty else { return }

        estimationTask?.cancel()
        estimationTask = Task { [weak self] in
            guard let self else { return }

            let q = self.quality
            let r = self.resolution
            let c = self.codec
            let urls = self.selectedVideos
            let svc = VideoCompressionService()
            var newEstimates: [URL: Int64] = [:]

            for url in urls {
                guard !Task.isCancelled else { return }
                newEstimates[url] = svc.estimateCompressedSize(
                    url: url, quality: q, resolution: r, codec: c
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

        let videos = selectedVideos
        let q = quality
        let r = resolution
        let c = codec
        let fmt = outputFormat
        let sizes = originalSizes

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let svc = VideoCompressionService()
            var compressionResults: [VideoCompressionItem] = []
            var errors: [String] = []

            for url in videos {
                guard !Task.isCancelled else { break }

                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let compressedName = "\(originalName)_compressed.\(fmt.fileExtension)"
                let outputDir = FileManager.default.temporaryDirectory
                let outputURL = outputDir.appendingPathComponent(compressedName)
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    let completedCount = compressionResults.count + errors.count
                    let totalCount = videos.count

                    try await svc.compress(
                        url: url, quality: q, resolution: r,
                        codec: c, outputFormat: fmt, outputURL: outputURL
                    ) { [weak self] prog in
                        Task { @MainActor [weak self] in
                            self?.progress = (Double(completedCount) + prog) / Double(totalCount)
                        }
                    }

                    let originalSize = sizes[url] ?? 0
                    var compressedSize = FileUtils.fileSize(of: outputURL)

                    // 兜底：压缩后体积 ≥ 原图 → 降级重压
                    if compressedSize >= originalSize && originalSize > 0 {
                        let retryURL = outputDir.appendingPathComponent("\(originalName)_retry.\(fmt.fileExtension)")
                        try? FileManager.default.removeItem(at: retryURL)

                        // 第一轮降级：跳一档质量
                        let retryQuality: VideoQuality
                        switch q {
                        case .high:   retryQuality = .medium
                        case .medium: retryQuality = .low
                        case .low:    retryQuality = .low  // 已最低，再降一半码率
                        }

                        do {
                            try await svc.compress(
                                url: url, quality: retryQuality, resolution: r,
                                codec: c, outputFormat: fmt, outputURL: retryURL
                            ) { _ in }
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

                        // 仍无效 → 保留原文件
                        if compressedSize >= originalSize {
                            try? FileManager.default.removeItem(at: outputURL)
                            try? FileManager.default.copyItem(at: url, to: outputURL)
                            compressedSize = originalSize
                        }
                    }

                    compressionResults.append(VideoCompressionItem(
                        originalURL: url,
                        compressedURL: outputURL,
                        originalSize: originalSize,
                        compressedSize: compressedSize
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let done = Double(compressionResults.count + errors.count)
                let total = Double(videos.count)
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
                        self.successMessage = "视频已是极致压缩状态，未进一步瘦身"
                    } else {
                        self.successMessage = "成功压缩 \(finalResults.count) 个视频，节省 \(savedPct)% 空间"
                    }
                } else if finalResults.isEmpty {
                    self.errorMessage = finalErrors.joined(separator: "\n")
                } else {
                    self.successMessage = "成功压缩 \(finalResults.count) 个视频，\(finalErrors.count) 个失败"
                }

                // 历史记录
                if !finalResults.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.compressedSize }
                    let savedPct = totalIn > 0 ? Int((1 - Double(totalOut) / Double(totalIn)) * 100) : 0
                    HistoryService().addRecord(
                        toolName: "视频压缩",
                        operationType: "批量压缩",
                        fileCount: finalResults.count,
                        inputFileNames: finalResults.map { $0.originalURL.lastPathComponent },
                        status: finalErrors.isEmpty ? "成功" : "部分成功",
                        inputSize: totalIn,
                        outputSize: totalOut,
                        descriptionText: "压缩 \(finalResults.count) 个视频，节省 \(max(0, savedPct))% 空间"
                    )
                }
            }
        }
    }

    // MARK: 保存结果

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

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }
}
