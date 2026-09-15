import Foundation

/// 统一缓存管理 — 所有中间处理文件写入固定缓存目录，30 分钟过期
enum CacheManager {
    /// 缓存过期时间（秒）
    static let expirationInterval: TimeInterval = 30 * 60

    // MARK: - 目录

    /// 缓存根目录 ~/Library/Caches/RuiTuOfficeMaster/
    static var rootDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("RuiTuOfficeMaster")
    }

    /// 图片处理缓存 ~/Library/Caches/RuiTuOfficeMaster/ImageCache/
    static var imageCacheDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("ImageCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 音视频处理缓存 ~/Library/Caches/RuiTuOfficeMaster/MediaCache/
    static var mediaCacheDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("MediaCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 文档处理缓存 ~/Library/Caches/RuiTuOfficeMaster/DocumentCache/
    static var documentCacheDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("DocumentCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 大小计算

    /// 缓存总大小（字节），实时遍历磁盘
    static var totalCacheSize: Int64 {
        cleanExpired()
        return directorySize(at: rootDirectory)
    }

    /// 格式化缓存大小（MB，保留 1 位小数）
    static var formattedCacheSize: String {
        let bytes = totalCacheSize
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.1f MB", mb)
    }

    // MARK: - 清理

    /// 清理全部缓存文件
    static func clearAll() {
        let dirs = [imageCacheDirectory, mediaCacheDirectory, documentCacheDirectory, rootDirectory]
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
        // 重建空目录
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    /// 清理过期缓存（超过 30 分钟未修改的文件）
    static func cleanExpired() {
        let now = Date()
        for dir in [imageCacheDirectory, mediaCacheDirectory, documentCacheDirectory] {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for url in contents {
                guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(mod) > expirationInterval else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 生成缓存文件 URL（指定目录 + 前缀 + 扩展名）
    static func cacheFileURL(in directory: URL, prefix: String, ext: String) -> URL {
        let name = "\(prefix)_\(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(name)
    }

    // MARK: - 内部

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  !isDir else { continue }
            total += FileUtils.fileSize(of: fileURL)
        }
        return total
    }
}
