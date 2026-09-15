import SwiftUI

/// 隐私声明条：所有功能页底部统一使用
struct PrivacyNoticeView: View {
    var body: some View {
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
}
