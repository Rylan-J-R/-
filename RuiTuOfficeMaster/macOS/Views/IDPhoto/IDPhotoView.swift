#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 证件照生成页面

struct IDPhotoView: View {
    @State private var viewModel = IDPhotoViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleSection
                    featureIntroSection
                    fileUploadSection
                    if viewModel.hasImage {
                        settingsSection
                        processSection
                    }
                    if viewModel.hasResult {
                        resultSection
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 900)
            }
            .background(AppColors.background)

            privacyNotice
                .padding(.bottom, 8)
        }
        .background(AppColors.background)
    }

    // MARK: 标题

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logoPath = Bundle.module.path(forResource: "Logo", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: logoPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
                Text("证件照生成")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
            }
            Text("上传正面照，一键换底色、裁尺寸、控大小，五步出片")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.top, 24)
    }

    // MARK: 功能介绍卡片

    private var featureIntroSection: some View {
        HStack(spacing: 16) {
            FeatureIntroItem(
                icon: "paintpalette.fill",
                title: "一键换底色",
                desc: "内置白/红/蓝三种标准底色，点击即换，无需手动抠图"
            )
            FeatureIntroItem(
                icon: "crop.rotate",
                title: "标准尺寸",
                desc: "一寸、二寸预设尺寸，自动适配比例，支持微调裁切"
            )
            FeatureIntroItem(
                icon: "arrow.down.circle",
                title: "精准控大小",
                desc: "自定义输出文件 KB 大小，智能压缩不超上限"
            )
            FeatureIntroItem(
                icon: "square.and.arrow.down",
                title: "一键导出",
                desc: "处理完直接导出 JPEG，即存即用，完全本地离线"
            )
        }
    }

    // MARK: 文件上传

    private var fileUploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 上传证件照原图")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            if let original = viewModel.originalPreview {
                VStack(spacing: 12) {
                    Image(nsImage: original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 360, maxHeight: 320)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.primary)
                        Text(viewModel.selectedImage?.lastPathComponent ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                        Text(viewModel.fileSizeText)
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Button(action: { viewModel.selectFile() }) {
                            Label("更换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        Button(action: { viewModel.clearAll() }) {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(AppColors.cardBackground)
                    .cornerRadius(8)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.square.fill")
                        .font(.system(size: 32))
                        .foregroundColor(AppColors.textSecondary.opacity(0.5))

                    Text("拖拽证件照原图到此处，或点击下方按钮选择")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)

                    Text("支持 JPG、PNG、HEIC、BMP、TIFF 格式")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.6))

                    Button(action: { viewModel.selectFile() }) {
                        Label("选择图片", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            AppColors.textSecondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )
                .background(AppColors.cardBackground.opacity(0.6))
                .cornerRadius(10)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }
            }
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. 参数设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(spacing: 20) {
                backgroundColorPicker
                toleranceControl
                Divider()
                sizeSelector
                Divider()
                kbControl
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

            // 预览
            previewArea
        }
    }

    // MARK: 背景色选择器

    private var backgroundColorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("背景底色")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            HStack(spacing: 12) {
                ForEach(IDPhotoBackground.allCases, id: \.self) { bg in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: NSColor(cgColor: bg.displayColor) ?? .white))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(
                                        viewModel.selectedBackground == bg
                                            ? AppColors.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                            )
                        Text(bg.name)
                            .font(.system(size: 13, weight: viewModel.selectedBackground == bg ? .semibold : .regular))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                viewModel.selectedBackground == bg
                                    ? AppColors.primaryLight : Color.gray.opacity(0.08)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.selectedBackground == bg
                                    ? AppColors.primary : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        viewModel.selectedBackground = bg
                        Task { await viewModel.refreshPreview() }
                    }
                }
            }
        }
    }

    // MARK: 容差控制

    private var toleranceControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("背景识别强度")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                Text(toleranceLabel)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }

            Slider(value: $viewModel.tolerance, in: 30...150, step: 5) {
                Text("容差")
            } onEditingChanged: { editing in
                if !editing {
                    Task { await viewModel.refreshPreview() }
                }
            }
            .frame(width: 240)

            HStack {
                Text("低")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
                Spacer()
                    .frame(width: 240)
                Text("高")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
            }
        }
    }

    private var toleranceLabel: String {
        if viewModel.tolerance < 45 { return "精准（保留更多细节）" }
        if viewModel.tolerance < 80 { return "标准（推荐）" }
        if viewModel.tolerance < 120 { return "较强（宽松匹配）" }
        return "强力（大面积替换）"
    }

    // MARK: 尺寸选择器

    private var sizeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("证件照尺寸")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            HStack(spacing: 12) {
                ForEach(IDPhotoSize.allCases, id: \.self) { size in
                    Text(size.name)
                        .font(.system(size: 13, weight: viewModel.selectedSize == size ? .semibold : .medium))
                        .foregroundColor(
                            viewModel.selectedSize == size ? .white : AppColors.textPrimary
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(
                                    viewModel.selectedSize == size
                                        ? AppColors.primary : AppColors.primaryLight
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                        .onTapGesture { viewModel.selectedSize = size }
                }
            }

            // 垂直位置微调滑块
            VStack(alignment: .leading, spacing: 4) {
                Text("裁切位置微调")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)

                    Slider(value: $viewModel.cropOffsetY, in: -1...1)
                        .frame(width: 200)

                    Image(systemName: "arrow.up")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)

                    Text(viewModel.cropOffsetY == 0 ? "居中" : viewModel.cropOffsetY > 0 ? "偏上" : "偏下")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                        .frame(width: 30, alignment: .center)
                }
            }
        }
    }

    // MARK: KB 控制

    private var kbControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输出文件大小上限")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            HStack(spacing: 12) {
                Slider(value: $viewModel.targetKB, in: viewModel.targetKBSliderRange, step: 5)
                    .frame(width: 240)

                TextField("", value: $viewModel.targetKB, format: .number)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)

                Text("KB")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    // MARK: 预览区域

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览效果")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.08))

                if let preview = viewModel.processedPreview {
                    GeometryReader { geometry in
                        let containerSize = geometry.size
                        let imageSize = preview.size
                        let imageRatio = imageSize.width / max(imageSize.height, 1)
                        let containerRatio = containerSize.width / max(containerSize.height, 1)
                        let cropRatio = viewModel.selectedSize.aspectRatio

                        let fitWidth: CGFloat = imageRatio > containerRatio
                            ? containerSize.width
                            : containerSize.height * imageRatio
                        let fitHeight: CGFloat = imageRatio > containerRatio
                            ? containerSize.width / imageRatio
                            : containerSize.height

                        ZStack(alignment: .center) {
                            Image(nsImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: fitWidth, height: fitHeight)
                                .position(x: containerSize.width / 2, y: containerSize.height / 2)

                            // 裁切框
                            let cropFrame = cropOverlayRect(
                                container: containerSize,
                                imageFit: CGSize(width: fitWidth, height: fitHeight),
                                cropRatio: cropRatio,
                                offsetY: viewModel.cropOffsetY
                            )

                            Rectangle()
                                .fill(.black.opacity(0.35))
                                .frame(
                                    width: containerSize.width,
                                    height: containerSize.height
                                )
                                .mask(
                                    Rectangle()
                                        .frame(
                                            width: containerSize.width,
                                            height: containerSize.height
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(Color.white, lineWidth: 2)
                                                .frame(
                                                    width: cropFrame.width,
                                                    height: cropFrame.height
                                                )
                                                .position(
                                                    x: cropFrame.midX,
                                                    y: cropFrame.midY
                                                )
                                                .blendMode(.destinationOut)
                                        )
                                )
                        }
                    }
                } else {
                    Text("正在加载预览...")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .cornerRadius(8)
        }
    }

    /// 计算裁切框在预览容器中的位置
    private func cropOverlayRect(
        container: CGSize,
        imageFit: CGSize,
        cropRatio: CGFloat,
        offsetY: CGFloat
    ) -> CGRect {
        let fitRatio = imageFit.width / max(imageFit.height, 1)

        let cropW: CGFloat
        let cropH: CGFloat
        if fitRatio > cropRatio {
            cropH = imageFit.height
            cropW = cropH * cropRatio
        } else {
            cropW = imageFit.width
            cropH = cropW / cropRatio
        }

        let centerX = container.width / 2
        let imageCenterY = container.height / 2
        let maxOffset = max((imageFit.height - cropH) / 2, 0)
        let centerY = imageCenterY - offsetY * maxOffset

        return CGRect(
            x: centerX - cropW / 2,
            y: centerY - cropH / 2,
            width: cropW,
            height: cropH
        )
    }

    // MARK: 处理

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. 开始处理")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            if viewModel.isProcessing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(
                        progress: Binding(get: { viewModel.progress }, set: { _ in }),
                        currentFile: "正在处理证件照..."
                    )
                }
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.process() }) {
                    Label("处理图片", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)

                if let msg = viewModel.successMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.success)
                }
                if let msg = viewModel.errorMessage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                }
            }
        }
    }

    // MARK: 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("处理结果")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()

                HStack(spacing: 8) {
                    Text("文件大小: \(FileUtils.formatSize(viewModel.resultFileSize))")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)

                    Button(action: { viewModel.exportImage() }) {
                        Label("导出保存", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let preview = viewModel.processedPreview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 360)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("所有文件全程本地离线处理，绝不上传云端，隐私百分百安全")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }

    // MARK: 拖拽处理

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.addFile(from: url)
                    }
                }
            }
        }
    }
}

#endif
