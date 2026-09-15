import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 转换结果

struct ConversionResultItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let convertedURL: URL
    let originalSize: Int64
    let convertedSize: Int64
    let targetFormat: ConversionFormat
}

// MARK: - 格式转换 ViewModel

@Observable
final class FormatConversionViewModel: @unchecked Sendable {

    // MARK: 文件选择
    var selectedFiles: [URL] = []
    var originalSizes: [URL: Int64] = [:]

    // MARK: 转换参数
    var targetFormat: ConversionFormat = .jpg

    // MARK: 处理状态
    var isProcessing = false
    var progress: Double = 0
    var currentFileName = ""

    // MARK: 结果
    var results: [ConversionResultItem] = []
    var successMessage: String?
    var errorMessage: String?

    private let service = FormatConversionService()

    // MARK: 计算属性

    var fileCountText: String {
        "已选择 \(selectedFiles.count) 个文件"
    }

    var originalTotalSizeText: String {
        let total = selectedFiles.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    var canExecute: Bool {
        !selectedFiles.isEmpty && !isProcessing
    }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = FormatConversionService.supportedInputFormats

        if panel.runModal() == .OK {
            addFiles(from: panel.urls)
        }
    }
#endif

    func addFiles(from urls: [URL]) {
        guard !isProcessing else { return }
        let newURLs = urls.filter { url in
            guard url.isFileURL, !selectedFiles.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return FormatConversionService.supportedInputFormats.contains(type)
        }
        selectedFiles.append(contentsOf: newURLs)
        for url in newURLs {
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        clearMessages()
    }

    // MARK: 管理已选文件

    func removeFile(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedFiles.firstIndex(of: url) else { return }
        selectedFiles.remove(at: index)
        originalSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
    }

    // MARK: 执行转换

    func executeConversion() {
        guard canExecute else { return }

        isProcessing = true
        progress = 0
        results = []
        clearMessages()

        let files = selectedFiles
        let fmt = targetFormat
        let sizes = originalSizes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let svc = FormatConversionService()
            var conversionResults: [ConversionResultItem] = []
            var errors: [String] = []

            for url in files {
                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let newName = "\(originalName)_\(UUID().uuidString.prefix(8)).\(fmt.fileExtension)"
                let outputDir = FileManager.default.temporaryDirectory
                let outputURL = outputDir.appendingPathComponent(newName)
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    try svc.convert(url: url, to: fmt, outputURL: outputURL)
                    let originalSize = sizes[url] ?? 0
                    let convertedSize = FileUtils.fileSize(of: outputURL)

                    conversionResults.append(ConversionResultItem(
                        originalURL: url,
                        convertedURL: outputURL,
                        originalSize: originalSize,
                        convertedSize: convertedSize,
                        targetFormat: fmt
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let currentProgress = Double(conversionResults.count + errors.count) / Double(files.count)
                let currentName = url.lastPathComponent
                DispatchQueue.main.async { [weak self] in
                    self?.progress = currentProgress
                    self?.currentFileName = currentName
                }
            }

            let finalResults = conversionResults
            let finalErrors = errors

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = finalResults

                if finalErrors.isEmpty {
                    self.successMessage = "成功转换 \(finalResults.count) 个文件"
                } else if finalResults.isEmpty {
                    self.errorMessage = finalErrors.joined(separator: "\n")
                } else {
                    self.successMessage = "成功转换 \(finalResults.count) 个文件，\(finalErrors.count) 个失败"
                }

                if !finalResults.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.convertedSize }
                    HistoryService().addRecord(
                        toolName: "格式转换",
                        operationType: "转为\(fmt.rawValue)",
                        fileCount: finalResults.count,
                        inputFileNames: finalResults.map { $0.originalURL.lastPathComponent },
                        status: finalErrors.isEmpty ? "成功" : "部分成功",
                        inputSize: totalIn,
                        outputSize: totalOut,
                        descriptionText: "将 \(finalResults.count) 个文件转换为 \(fmt.rawValue) 格式"
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
                let dest = dir.appendingPathComponent(result.convertedURL.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: result.convertedURL, to: dest)
                    savedCount += 1
                } catch {
                    saveErrors.append("\(result.convertedURL.lastPathComponent): \(error.localizedDescription)")
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
