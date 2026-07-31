import SwiftUI

/// 设计令牌：暗色优先、高对比（冷库/后厨场景），8pt 栅格，圆角 14。
extension Color {
    static let brand    = Color(hex: "#007AFF")
    static let success  = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning  = Color(hex: "#FF9F0A")
    static let danger   = Color(hex: "#FF3B30")
    /// 深色背景下用于正文的危险色（比 danger 更亮，保证对比度）
    static let dangerOnDark = Color(hex: "#FF453A")
    static let surface  = Color(.secondarySystemBackground)
    static let hairline = Color(.separator)

    /// 解析 #RRGGBB（可选 # 前缀）
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = h.hasPrefix("#") ? String(h.dropFirst()) : h
        var rgb: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

/// 间距令牌（8pt 栅格）
struct AppSpacing {
    static let s1: CGFloat = 8
    static let s2: CGFloat = 12
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
}

/// 圆角令牌
struct AppRadius {
    static let standard: CGFloat = 12
}

/// 卡片容器
struct AppCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.standard, style: .continuous))
    }
}

/// 主操作按钮（点击区 ≥44pt）
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
                .background(Color.brand)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 危险操作按钮
struct DangerButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
                .background(Color.danger)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 空状态
struct EmptyState: View {
    let title: String
    var hint: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title).font(.headline).foregroundColor(.secondary)
            if let hint { Text(hint).font(.subheadline).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// 预警横幅
struct BannerView: View {
    let tone: Color
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(tone)
            Text(message).font(.subheadline).foregroundColor(.primary)
            Spacer()
        }
        .padding(12)
        .background(tone.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
