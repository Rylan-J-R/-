import SwiftUI
import AppKit

/// 通用占位页面 — 用于功能尚未实现的页面展示
struct PlaceholderPage: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundColor(AppColors.primary.opacity(0.6))

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    logoImage
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                }

                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Text("功能开发中...")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(AppColors.primaryLight)
                .cornerRadius(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }

    @ViewBuilder
    private var logoImage: some View {
        if let logoPath = Bundle.module.path(forResource: "Logo", ofType: "png") {
            if let nsImage = NSImage(contentsOfFile: logoPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            }
        }
    }
}
