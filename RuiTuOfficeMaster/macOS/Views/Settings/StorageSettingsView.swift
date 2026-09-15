#if os(macOS)
import SwiftUI

/// 存储管理 — 缓存占用展示与一键清理
struct StorageSettingsView: View {
    @State private var cacheSize: Int64 = 0
    @State private var recordCount: Int = 0
    @State private var isCalculating = true
    @State private var isClearing = false
    @State private var showClearAlert = false
    @State private var clearedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 缓存占用概览
                SettingsSection(title: "缓存数据") {
                    HStack(alignment: .bottom, spacing: 24) {
                        // 缓存总量
                        VStack(alignment: .leading, spacing: 6) {
                            Text("缓存占用")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)

                            if isCalculating {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                    Text("计算中...")
                                        .font(.system(size: 14))
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            } else {
                                Text(FileUtils.formatSize(cacheSize))
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(AppColors.textPrimary)
                            }
                        }

                        Divider().frame(height: 40)

                        // 记录数量
                        VStack(alignment: .leading, spacing: 6) {
                            Text("历史记录")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)
                            Text("\(recordCount) 条")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }

                    Divider().opacity(0.5).padding(.vertical, 2)

                    // 清理按钮
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("清理全部缓存")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)
                            Text("删除所有历史记录与临时文件，释放磁盘空间")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary)
                        }

                        Spacer()

                        Button {
                            showClearAlert = true
                        } label: {
                            HStack(spacing: 6) {
                                if isClearing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "trash")
                                }
                                Text("清理")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(cacheSize > 0 ? AppColors.error : Color.gray.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(cacheSize == 0 || isClearing || isCalculating)
                    }
                    .padding(.top, 4)
                }

                // 缓存说明
                SettingsSection(title: "缓存包含") {
                    VStack(alignment: .leading, spacing: 10) {
                        CacheItemRow(icon: "clock.arrow.circlepath", text: "历史操作记录数据")
                        CacheItemRow(icon: "doc.text", text: "处理过程中产生的临时文件")
                    }
                }
            }
        }
        .onAppear { calculateCacheSize() }
        .onReceive(NotificationCenter.default.publisher(for: .cacheDidChange)) { _ in
            calculateCacheSize()
        }
        .alert("确认清理缓存", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) { clearCache() }
        } message: {
            Text("将删除全部 \(recordCount) 条历史记录和所有临时文件（约 \(FileUtils.formatSize(cacheSize))），此操作不可撤销。")
        }
        .overlay(alignment: .top) {
            if clearedToast {
                ToastBanner(message: "缓存已清理完成")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: clearedToast)
    }

    // MARK: - 缓存计算

    private func calculateCacheSize() {
        isCalculating = true
        Task.detached {
            let total = CacheManager.totalCacheSize
            let count = HistoryService().fetchAll().count

            await MainActor.run {
                cacheSize = total
                recordCount = count
                isCalculating = false
            }
        }
    }

    // MARK: - 缓存清理

    private func clearCache() {
        isClearing = true
        Task.detached {
            HistoryService().clearAll()
            CacheManager.clearAll()

            await MainActor.run {
                isClearing = false
                cacheSize = 0
                recordCount = 0
                clearedToast = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    clearedToast = false
                }
            }
        }
    }
}

// MARK: - 缓存项目行

private struct CacheItemRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textPrimary)
        }
    }
}


#endif
