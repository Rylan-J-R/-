import Foundation

/// 文件工具方法，供 Service / ViewModel / View 跨层使用
enum FileUtils {

    /// 获取文件大小（字节），失败返回 0
    static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }

    /// 格式化字节数为人类可读字符串（如 "1.5 MB"）
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
