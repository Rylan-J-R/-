import Foundation

// MARK: - 批量改名服务

/// 改名模式枚举
enum RenameMode: String, CaseIterable {
    case prefix = "添加前缀"
    case suffix = "添加后缀"
    case replace = "查找替换"
    case numbering = "序号命名"

    var systemImage: String {
        switch self {
        case .prefix: return "textformat.abc"
        case .suffix: return "textformat.abc.dottedunderline"
        case .replace: return "arrow.triangle.swap"
        case .numbering: return "list.number"
        }
    }
}

/// 单条改名预览
struct RenamePreviewItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let originalName: String
    let newName: String
    let isValid: Bool
    /// 冲突原因：nil 表示无冲突，"重名"表示目标文件已存在，"无权限"表示文件不可写
    var conflictReason: String? = nil
}

/// 改名结果
enum RenameResult {
    case success(count: Int)
    case failure(errors: [String])
}

/// 批量改名逻辑处理
struct FileRenameService {

    /// 根据改名模式和参数，生成新的文件名（不含扩展名部分）
    func generateNewName(
        originalName: String,
        mode: RenameMode,
        prefix: String,
        suffix: String,
        findText: String,
        replaceText: String,
        numberText: String,
        number: Int,
        numberDigits: Int
    ) -> String {
        let baseName = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension

        let newBase: String
        switch mode {
        case .prefix:
            newBase = prefix + baseName
        case .suffix:
            newBase = baseName + suffix
        case .replace:
            if findText.isEmpty {
                newBase = baseName
            } else {
                newBase = baseName.replacingOccurrences(of: findText, with: replaceText)
            }
        case .numbering:
            let format = "%0\(numberDigits)d"
            let numStr = String(format: format, number)
            newBase = numberText + "_\(numStr)"
        }

        if ext.isEmpty {
            return newBase
        }
        return "\(newBase).\(ext)"
    }

    /// 生成预览列表
    func generatePreview(
        files: [URL],
        mode: RenameMode,
        prefix: String,
        suffix: String,
        findText: String,
        replaceText: String,
        numberText: String,
        startNumber: Int,
        numberDigits: Int
    ) -> [RenamePreviewItem] {
        let fileManager = FileManager.default
        return files.enumerated().map { index, url in
            let originalName = url.lastPathComponent
            let newName = generateNewName(
                originalName: originalName,
                mode: mode,
                prefix: prefix,
                suffix: suffix,
                findText: findText,
                replaceText: replaceText,
                numberText: numberText,
                number: startNumber + index,
                numberDigits: numberDigits
            )
            let isValid = !newName.isEmpty && newName != originalName

            // 检测冲突：目标文件是否已存在
            var conflictReason: String? = nil
            if isValid {
                let dir = url.deletingLastPathComponent()
                let targetURL = dir.appendingPathComponent(newName)
                // 只有目标路径与源文件不同时才检查（同名且同路径不算冲突）
                if targetURL != url && fileManager.fileExists(atPath: targetURL.path) {
                    conflictReason = "目标文件已存在"
                }
                // 检测源文件是否可写
                if !fileManager.isWritableFile(atPath: url.path) {
                    conflictReason = "文件无写入权限"
                }
            }

            return RenamePreviewItem(
                originalURL: url,
                originalName: originalName,
                newName: newName,
                isValid: isValid,
                conflictReason: conflictReason
            )
        }
    }

    /// 执行批量改名，返回结果
    func execute(
        previewItems: [RenamePreviewItem],
        progressHandler: @escaping (Double) -> Void
    ) -> RenameResult {
        let fileManager = FileManager.default
        var errors: [String] = []
        let total = previewItems.count

        for (index, item) in previewItems.enumerated() {
            let dir = item.originalURL.deletingLastPathComponent()
            var newURL = dir.appendingPathComponent(item.newName)

            // 目标文件已存在时，自动加编号避让（如 "照片.txt" → "照片 (1).txt"）
            if newURL != item.originalURL, fileManager.fileExists(atPath: newURL.path) {
                var found = false
                let baseName = (item.newName as NSString).deletingPathExtension
                let ext = (item.newName as NSString).pathExtension
                for counter in 1...99 {
                    let altName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
                    let altURL = dir.appendingPathComponent(altName)
                    if !fileManager.fileExists(atPath: altURL.path) {
                        newURL = altURL
                        found = true
                        break
                    }
                }
                if !found {
                    errors.append("无法自动避让: \(item.newName)，已存在同名文件且编号 1-99 均被占用")
                    progressHandler(Double(index + 1) / Double(total))
                    continue
                }
            }

            do {
                try fileManager.moveItem(at: item.originalURL, to: newURL)
            } catch {
                errors.append("改名失败: \(item.originalName) → \(item.newName), 原因: \(error.localizedDescription)")
            }

            progressHandler(Double(index + 1) / Double(total))
        }

        let successCount = total - errors.count
        if errors.isEmpty {
            return .success(count: successCount)
        } else {
            return .failure(errors: errors)
        }
    }
}
