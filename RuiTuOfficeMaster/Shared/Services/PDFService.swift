import Foundation
import PDFKit
import UniformTypeIdentifiers
import CoreGraphics
import AppKit

typealias PlatformFont = NSFont

// MARK: - PDF 错误

enum PDFError: LocalizedError {
    case invalidSource(url: URL)
    case sourceEncrypted(url: URL)
    case writeFailed
    case noPages
    case invalidPageRange(String)
    case watermarkFailed

    var errorDescription: String? {
        switch self {
        case .invalidSource(let url):
            return "无法读取 PDF 文件：\(url.lastPathComponent)"
        case .sourceEncrypted(let url):
            return "文件已加密，请先解密后再操作：\(url.lastPathComponent)"
        case .writeFailed:
            return "写入 PDF 文件失败"
        case .noPages:
            return "PDF 文件没有页面"
        case .invalidPageRange(let range):
            return "页码范围格式不正确：\(range)"
        case .watermarkFailed:
            return "添加水印失败"
        }
    }
}

// MARK: - 水印类型

enum WatermarkType {
    case text(String, fontSize: CGFloat, color: CGColor, rotation: CGFloat, opacity: CGFloat)
    case image(URL, scale: CGFloat, opacity: CGFloat)
}

// MARK: - 加密配置

struct EncryptionConfig {
    let userPassword: String
    let ownerPassword: String
    let allowPrinting: Bool
    let allowCopying: Bool
}

// MARK: - 拆分范围

struct SplitRange {
    let start: Int
    let end: Int
}

// MARK: - PDF 服务

struct PDFService {

    // MARK: 工具

    private func loadCGImage(from url: URL) -> CGImage? {
        if let nsImage = NSImage(contentsOf: url) {
            return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    // MARK: 支持格式

    static let supportedFormats: [UTType] = [.pdf]

    // 工具方法：文件大小相关已统一收拢到 FileUtils

    /// 获取 PDF 总页数
    func pageCount(of url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return 0 }
        return doc.pageCount
    }

    // MARK: PDF 合并

    func merge(urls: [URL], outputURL: URL) throws {
        let dest = PDFDocument()

        for url in urls {
            guard let src = PDFDocument(url: url) else {
                if FileManager.default.isReadableFile(atPath: url.path) {
                    throw PDFError.sourceEncrypted(url: url)
                }
                throw PDFError.invalidSource(url: url)
            }
            for i in 0..<src.pageCount {
                if let page = src.page(at: i) {
                    dest.insert(page, at: dest.pageCount)
                }
            }
        }

        guard dest.pageCount > 0 else { throw PDFError.noPages }
        guard dest.write(to: outputURL) else { throw PDFError.writeFailed }
    }

    // MARK: PDF 拆分

    func split(url: URL, ranges: [SplitRange], outputDir: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else {
            if FileManager.default.isReadableFile(atPath: url.path) {
                throw PDFError.sourceEncrypted(url: url)
            }
            throw PDFError.invalidSource(url: url)
        }

        var outputURLs: [URL] = []
        let baseName = (url.lastPathComponent as NSString).deletingPathExtension

        for range in ranges {
            let chunk = PDFDocument()
            let actualStart = max(0, range.start - 1)
            let actualEnd = min(range.end, doc.pageCount)
            let oneBasedStart = actualStart + 1
            let oneBasedEnd = actualEnd

            for i in actualStart..<actualEnd {
                if let page = doc.page(at: i) {
                    chunk.insert(page, at: chunk.pageCount)
                }
            }

            guard chunk.pageCount > 0 else { continue }

            let rangeLabel: String
            if oneBasedStart == oneBasedEnd {
                rangeLabel = "\(baseName)_第\(oneBasedStart)页"
            } else {
                rangeLabel = "\(baseName)_第\(oneBasedStart)-\(oneBasedEnd)页"
            }
            let outURL = outputDir.appendingPathComponent("\(rangeLabel).pdf")
            try? FileManager.default.removeItem(at: outURL)

            guard chunk.write(to: outURL) else { throw PDFError.writeFailed }
            outputURLs.append(outURL)
        }

        guard !outputURLs.isEmpty else { throw PDFError.noPages }
        return outputURLs
    }

    // MARK: PDF 加密

    func encrypt(url: URL, config: EncryptionConfig, outputURL: URL) throws {
        guard let doc = PDFDocument(url: url) else {
            if FileManager.default.isReadableFile(atPath: url.path) {
                throw PDFError.sourceEncrypted(url: url)
            }
            throw PDFError.invalidSource(url: url)
        }

        var options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: config.userPassword,
            .ownerPasswordOption: config.ownerPassword,
        ]

        // kCGPDFAllowsLowQualityPrinting=1, kCGPDFAllowsHighQualityPrinting=2
        // kCGPDFAllowsContentCopying=16
        var permissions: Int = 0
        if config.allowPrinting {
            permissions |= 3
        }
        if config.allowCopying {
            permissions |= 16
        }
        if permissions != 0 {
            options[.accessPermissionsOption] = NSNumber(value: permissions)
        }

        guard doc.write(to: outputURL, withOptions: options) else {
            throw PDFError.writeFailed
        }
    }

    // MARK: 水印

    func addWatermark(url: URL, type: WatermarkType, outputURL: URL) throws {
        guard let sourceDoc = PDFDocument(url: url) else {
            if FileManager.default.isReadableFile(atPath: url.path) {
                throw PDFError.sourceEncrypted(url: url)
            }
            throw PDFError.invalidSource(url: url)
        }

        let cacheDir = CacheManager.documentCacheDirectory
        let dest = PDFDocument()

        for i in 0..<sourceDoc.pageCount {
            guard let page = sourceDoc.page(at: i),
                  let pageRef = page.pageRef else { continue }

            let pageRect = page.bounds(for: .mediaBox)
            var mediaBox = pageRect

            let tempURL = cacheDir.appendingPathComponent("wm_temp_\(UUID().uuidString).pdf")
            try? FileManager.default.removeItem(at: tempURL)

            guard let pdfContext = CGContext(tempURL as CFURL, mediaBox: &mediaBox, nil) else {
                throw PDFError.watermarkFailed
            }

            // 绘制原始页面
            pdfContext.beginPDFPage(nil)
            pdfContext.drawPDFPage(pageRef)

            // 绘制水印
            pdfContext.saveGState()

            switch type {
            case .text(let text, let fontSize, let color, let rotation, let opacity):
                pdfContext.setAlpha(opacity)
                pdfContext.translateBy(x: pageRect.midX, y: pageRect.midY)
                pdfContext.rotate(by: rotation * .pi / 180)

                let platformColor = NSColor(cgColor: color) ?? NSColor.gray
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: PlatformFont.systemFont(ofSize: fontSize),
                    .foregroundColor: platformColor,
                ]
                let attrStr = NSAttributedString(string: text, attributes: attrs)
                let line = CTLineCreateWithAttributedString(attrStr)
                let bounds = CTLineGetImageBounds(line, pdfContext)
                pdfContext.textMatrix = .identity
                pdfContext.translateBy(x: -bounds.width / 2, y: -bounds.height / 2)
                CTLineDraw(line, pdfContext)

            case .image(let imageURL, let scale, let opacity):
                guard let cgImage = loadCGImage(from: imageURL) else {
                    pdfContext.restoreGState()
                    pdfContext.endPDFPage()
                    pdfContext.closePDF()
                    continue
                }
                pdfContext.setAlpha(opacity)
                let imgW = CGFloat(cgImage.width) * scale
                let imgH = CGFloat(cgImage.height) * scale
                let drawRect = CGRect(
                    x: pageRect.midX - imgW / 2,
                    y: pageRect.midY - imgH / 2,
                    width: imgW,
                    height: imgH
                )
                pdfContext.draw(cgImage, in: drawRect)
            }

            pdfContext.restoreGState()
            pdfContext.endPDFPage()
            pdfContext.closePDF()

            // 加载临时页并加入结果文档
            if let tempDoc = PDFDocument(url: tempURL),
               let newPage = tempDoc.page(at: 0) {
                dest.insert(newPage, at: dest.pageCount)
            }
        }

        guard dest.pageCount > 0 else { throw PDFError.noPages }
        guard dest.write(to: outputURL) else { throw PDFError.writeFailed }
    }
}
