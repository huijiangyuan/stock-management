//
//  ModelManagerView.swift
//  端侧 MiniCPM-V 4.6 模型管理（下载 / 加载 / 手动兜底 / 安全校验）
//

import SwiftUI

struct ModelManagerView: View {
    @State private var mgr = ModelManager.shared
    @State private var source: ModelManager.Source = .modelScope
    @State private var customURL = ""
    @State private var showCustomRisk = false
    @State private var pendingCustom = false

    private var memoryAssessment: OnDeviceMemoryAssessment {
        OnDeviceSafeEnvironment.evaluate(
            phase: mgr.loaded ? .imageInference : .modelLoad
        )
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("模型文件")
                    Spacer()
                    Text(mgr.modelPresent ? "已存在" : "缺失")
                        .foregroundColor(mgr.modelPresent ? .brand : .danger)
                }
                HStack {
                    Text("MiniCPM-V 内存准入")
                    Spacer()
                    Text(memoryAssessment.safe ? "通过" : "不足")
                        .foregroundColor(memoryAssessment.safe ? .brand : .danger)
                }
                HStack {
                    Text("推理引擎")
                    Spacer()
                    Text(mgr.loaded ? "已加载" : "未加载")
                        .foregroundColor(mgr.loaded ? .brand : .secondary)
                }
                if !mgr.message.isEmpty {
                    Text(mgr.message).font(.caption).foregroundColor(.secondary)
                }
            } header: { Label("端侧模型状态", systemImage: "cpu") }

            Section {
                Picker("下载源", selection: $source) {
                    ForEach(ModelManager.Source.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .onChange(of: source) { newValue in
                    if newValue == .custom { pendingCustom = true; showCustomRisk = true }
                }

                if source == .custom {
                    TextField("自定义 GGUF 地址（https）", text: $customURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("自定义地址须为 https 公网地址，且不能是内网 / 本机地址。仅在你完全信任该来源时使用。")
                        .font(.caption).foregroundColor(.warning)
                }

                Button {
                    if source == .custom {
                        mgr.download(source: .custom, customURL: customURL)
                    } else {
                        mgr.download(source: source)
                    }
                } label: {
                    if case .downloading(let p) = mgr.state {
                        Label("下载中 \(Int(p * 100))%", systemImage: "arrow.down.circle")
                    } else {
                        Label("下载 MiniCPM-V 4.6（约 1.6 GB）", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(downloading || mgr.loaded || isLoading)

                if mgr.modelPresent && !mgr.loaded {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("正在校验与加载模型...")
                                .font(.subheadline)
                                .foregroundColor(.brand)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            Task {
                                await mgr.load()
                            }
                        } label: {
                            Label("加载模型", systemImage: "bolt.fill")
                        }
                    }
                }
            } header: { Label("下载与加载模型", systemImage: "icloud.and.arrow.down") }

            Section {
                Text("若下载不稳定，可用电脑把以下两个文件放入 App 的「资料」(Documents) 目录，App 会自动识别：")
                    .font(.caption).foregroundColor(.secondary)
                Text("• \(ModelManager.llmFileName)\n• \(ModelManager.mmprojFileName)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("iOS：在「文件」App 中长按文件 → 共享 → 存入「库存管理」即可。")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Label("手动导入（兜底）", systemImage: "folder") }

            Section {
                Text(mgr.expectedHashDisplay)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("下载完成后会流式计算 sha256 并与内置预期哈希比对；手动放入的文件在「加载」时同样校验，防止被篡改。")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Label("安全校验", systemImage: "checkmark.shield") }

            Section {
                HStack(alignment: .top) {
                    Image(systemName: memoryAssessment.safe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(memoryAssessment.safe ? .brand : .danger)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memoryAssessment.safe
                             ? "内存检查通过，可以运行 MiniCPM-V 4.6。"
                             : memoryAssessment.reason)
                        Text("官方 GGUF CPU 运行约占 2 GB，推荐设备 RAM ≥ 6 GB。本 App 加载前要求当前进程至少可用 2.7 GB；模型加载后，每次图片推理前至少保留 1.5 GB。")
                            .foregroundColor(.secondary)
                        Text(memoryAssessment.diagnosticSummary)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            } header: { Label("设备能力", systemImage: "memorychip") }
        }
        .navigationTitle("端侧模型管理")
        .alert("自定义下载源风险提示", isPresented: $showCustomRisk) {
            Button("取消", role: .cancel) {
                source = .modelScope
            }
            Button("我信任该来源，继续") { pendingCustom = false }
        } message: {
            Text("自定义地址不经过官方域名白名单与证书锁定（SPKI pinning），仅做 https + 公网校验。请确认来源可信，下载内容将通过 sha256 校验。继续？")
        }
    }

    private var downloading: Bool {
        if case .downloading = mgr.state { return true }
        return false
    }

    private var isLoading: Bool {
        if mgr.state == .loading || mgr.state == .verifying { return true }
        return false
    }
}
