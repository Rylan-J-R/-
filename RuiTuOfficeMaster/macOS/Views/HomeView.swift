#if os(macOS)
import SwiftUI

/// 首页 — 功能卡片总览
struct HomeView: View {
    @Binding var selectedNav: NavItem

    /// 卡片数据（工具类）
    private let toolCards: [(NavItem, String)] = [
        (.fileRename, "添加前缀/后缀、查找替换、序号命名"),
        (.imageProcessing, "压缩图片、调整尺寸"),
        (.formatConversion, "JPG/PNG/WebP/HEIC/BMP/TIFF 格式互转"),
        (.idPhoto, "自拍生成证件照，换底色、裁切、美颜"),
        (.pdfTools, "PDF 合并/拆分/加密/水印 + Word/PDF 格式互转"),
        (.videoCompression, "压缩视频文件，调节质量与分辨率"),
        (.mediaConversion, "语音转字幕、音频批量处理、GIF 生成与压缩"),
        (.ocr, "从图片中提取文字，支持中英文等多语言，纯本地离线识别"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 页面标题
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        // Logo 图标
                        if let logoPath = Bundle.module.path(forResource: "Logo", ofType: "png"),
                           let nsImage = NSImage(contentsOfFile: logoPath) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                        }
                        Text("锐途办公大师")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("一站式文件批量处理，让办公更高效")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 功能卡片区域
                VStack(alignment: .leading, spacing: 16) {
                    Text("全部工具")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        ForEach(toolCards, id: \.0.id) { item, description in
                            FeatureCard(
                                title: item.rawValue,
                                description: description,
                                systemImage: item.systemImage
                            ) {
                                selectedNav = item
                            }
                        }
                    }
                }

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 900)
        }
        .background(AppColors.background)
    }
}

#endif
