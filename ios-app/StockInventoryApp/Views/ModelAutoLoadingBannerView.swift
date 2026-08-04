//
//  ModelAutoLoadingBannerView.swift
//  库存管理 App · 端侧 AI 模型自动预加载动态提示组件
//
//  当检测到本地已存在 GGUF 模型文件且处于校验/自动加载阶段时，
//  在 AI 识别与建库界面顶部展示优雅的 Progress 动画与加载进度提示。
//

import SwiftUI

struct ModelAutoLoadingBannerView: View {
    @State private var modelMgr = ModelManager.shared

    var body: some View {
        Group {
            switch modelMgr.state {
            case .verifying, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile")
                                .font(.caption.bold())
                            Text("端侧 AI 模型自动加载中…")
                                .font(.subheadline)
                                .fontWeight(.bold)
                        }
                        Text(modelMgr.message.isEmpty ? "正在初始化 MiniCPM-V 4.6 内存模型与 NPU 加速..." : modelMgr.message)
                            .font(.caption2)
                            .opacity(0.9)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.brand, Color.brand.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.brand.opacity(0.3), radius: 6, x: 0, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: modelMgr.state)

            default:
                EmptyView()
            }
        }
    }
}
