import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers

// MARK: - 证件照 ViewModel

@Observable
final class IDPhotoViewModel: @unchecked Sendable {

    // MARK: 文件

    var selectedImage: URL?
    var fileSize: Int64 = 0

    // MARK: 参数

    var selectedBackground: IDPhotoBackground = .white
    var selectedSize: IDPhotoSize = .oneInch
    var targetKB: Double = 120
    /// 裁切垂直偏移（-1 底部 ~ 1 顶部，0 居中）
    var cropOffsetY: CGFloat = 0
    /// 背景替换容差（曼哈顿距离，40~160）
    var tolerance: Double = 70

    // MARK: 预览

#if os(macOS)
    var originalPreview: NSImage?
    /// 背景替换后的实时预览
    var processedPreview: NSImage?
#endif

    // MARK: 结果

    var resultCGImage: CGImage?
    var resultData: Data?
    var resultFileSize: Int64 = 0

    // MARK: 原始图片缓存（CGImage，避免重复加载）

    private var cachedOriginalCG: CGImage?

    // MARK: 背景遮罩缓存（底色切换毫秒级响应）

    private var cachedMask: BackgroundMask?
    private var cachedMaskTolerance: Int = 70

    // MARK: 状态

    var isProcessing = false
    var progress: Double = 0
    var errorMessage: String?
    var successMessage: String?

    // MARK: 计算属性

    var hasImage: Bool { selectedImage != nil }
    var hasResult: Bool { resultData != nil }

    var fileSizeText: String {
        FileUtils.formatSize(fileSize)
    }

    var targetKBSliderRange: ClosedRange<Double> { 10...500 }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "选择证件照原图"
        panel.allowedContentTypes = IDPhotoService.supportedFormats

        if panel.runModal() == .OK, let url = panel.urls.first {
            setImage(url)
        }
    }
#endif

    func addFile(from url: URL) {
        guard !isProcessing, url.isFileURL else { return }
        guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
              let type = UTType(uti),
              IDPhotoService.supportedFormats.contains(type) else { return }
        setImage(url)
    }

    private func setImage(_ url: URL) {
        let service = IDPhotoService()
        selectedImage = url
        fileSize = FileUtils.fileSize(of: url)

        if let cgImage = try? service.loadImage(from: url) {
            cachedOriginalCG = cgImage
#if os(macOS)
            originalPreview = service.makePreview(from: cgImage)
#endif
            resultCGImage = nil
            resultData = nil
            resultFileSize = 0
#if os(macOS)
            processedPreview = nil
#endif
            cachedMask = nil  // 新图片 → 遮罩缓存失效
            resetSettings()
            clearMessages()
            Task { await refreshPreview() }
        } else {
            errorMessage = "无法加载图片"
        }
    }

    private func resetSettings() {
        selectedBackground = .white
        selectedSize = .oneInch
        targetKB = 120
        cropOffsetY = 0
        tolerance = 70
    }

    func clearAll() {
        guard !isProcessing else { return }
        selectedImage = nil
        fileSize = 0
        cachedOriginalCG = nil
        cachedMask = nil
#if os(macOS)
        originalPreview = nil
#endif
#if os(macOS)
        processedPreview = nil
#endif
        resultCGImage = nil
        resultData = nil
        resultFileSize = 0
        resetSettings()
        clearMessages()
    }

    // MARK: 实时预览（遮罩缓存 + 快速合成）

    func refreshPreview() async {
        guard !isProcessing, let original = cachedOriginalCG else { return }
        let service = IDPhotoService()
        let targetBg = selectedBackground
        let tol = Int(tolerance)

        let processed: CGImage
        do {
            // 快捷检查：原图背景已接近目标色，跳过所有处理
            let bg = service.detectBackgroundColor(of: original)
            let target = targetBg.rgbBytes
            let dr = Int32(bg.r) - Int32(target.r)
            let dg = Int32(bg.g) - Int32(target.g)
            let db = Int32(bg.b) - Int32(target.b)
            if abs(dr) + abs(dg) + abs(db) < 30 {
#if os(macOS)
                await MainActor.run { processedPreview = originalPreview }
#endif
                return
            }

            // 检查遮罩缓存是否有效
            let mask: BackgroundMask
            if let cached = cachedMask, cached.width == original.width,
               cached.height == original.height, cachedMaskTolerance == tol {
                mask = cached
            } else {
                // 缓存失效 → 重新计算遮罩（昂贵，仅此一次）
                mask = try await Task.detached(priority: .userInitiated) {
                    try service.computeMask(image: original, tolerance: tol)
                }.value
                cachedMask = mask
                cachedMaskTolerance = tol
            }

            // 用缓存的遮罩 + 新底色快速合成（毫秒级）
            processed = try await Task.detached(priority: .userInitiated) {
                try service.applyMask(mask, targetColor: targetBg, to: original)
            }.value

            await MainActor.run {
#if os(macOS)
                processedPreview = service.makePreview(from: processed)
#endif
                resultCGImage = processed
            }
        } catch {
            await MainActor.run {
#if os(macOS)
                processedPreview = originalPreview
#endif
            }
        }
    }

    // MARK: 处理（背景替换 + 裁切 + 压缩）

    func process() {
        guard !isProcessing else { return }
        guard let original = cachedOriginalCG else {
            errorMessage = "请先选择图片"
            return
        }

        isProcessing = true
        progress = 0
        errorMessage = nil
        successMessage = nil

        Task(priority: .userInitiated) {
            let service = IDPhotoService()
            let targetBg = selectedBackground
            let tol = Int(tolerance)
            do {
                await updateProgress(0.15)

                // 1. 背景替换
                let withNewBg = try await Task.detached(priority: .userInitiated) {
                    let bg = service.detectBackgroundColor(of: original)
                    let target = targetBg.rgbBytes
                    let dr = Int32(bg.r) - Int32(target.r)
                    let dg = Int32(bg.g) - Int32(target.g)
                    let db = Int32(bg.b) - Int32(target.b)
                    let dist = abs(dr) + abs(dg) + abs(db)
                    if dist < 30 { return original }
                    return try service.replaceBackground(
                        image: original,
                        targetColor: targetBg,
                        tolerance: tol
                    )
                }.value

                await updateProgress(0.40)

                // 2. 按比例裁切（保留原分辨率，不缩小）
                let cropped = try service.cropToRatio(
                    image: withNewBg,
                    ratio: selectedSize.aspectRatio,
                    offsetY: cropOffsetY
                )

                await updateProgress(0.70)

                // 3. KB 精准压缩（保留原图分辨率）
                let data = try service.compressToTargetSize(
                    image: cropped,
                    targetKB: Int(targetKB)
                )

                await updateProgress(1.0)

                await MainActor.run {
                    resultCGImage = cropped
                    resultData = data
                    resultFileSize = Int64(data.count)
#if os(macOS)
                    processedPreview = service.makePreview(from: cropped)
#endif
                    isProcessing = false
                    successMessage = "处理完成，文件大小 \(FileUtils.formatSize(resultFileSize))"
                }
            } catch {
                await handleError(error)
            }
        }
    }

    // MARK: 导出

    #if os(macOS)
    @MainActor
    func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "证件照_\(selectedBackground.name)_\(selectedSize.name).jpg"
        panel.title = "导出证件照"

        if panel.runModal() == .OK, let url = panel.url {
            let service = IDPhotoService()
            do {
                if let data = resultData {
                    try service.exportData(data, to: url)
                } else if let image = resultCGImage {
                    try service.exportImage(image, to: url)
                } else {
                    errorMessage = "没有可导出的图片，请先处理"
                    return
                }
                successMessage = "已导出到 \(url.lastPathComponent)"
            } catch {
                errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
    #endif

    // MARK: 进度 & 错误

    @MainActor
    private func updateProgress(_ value: Double) {
        progress = value
    }

    @MainActor
    private func handleError(_ error: Error) {
        isProcessing = false
        progress = 0
        errorMessage = error.localizedDescription
    }

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}
