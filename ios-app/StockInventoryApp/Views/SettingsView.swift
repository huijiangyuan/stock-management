import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation

struct SettingsView: View {
    @Environment(\.modelContext) private var ctx
    @State private var shareURL: URL?
    @State private var showImport = false
    @State private var message: String?

    @State private var keyText: String = VisionSettings.shared.apiKey ?? ""
    @State private var showPrivacy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 视觉识别（云端 VLM）") {
                    Picker("服务商", selection: providerBinding) {
                        Text("DashScope 通义千问（中国境内）").tag(VisionSettings.Provider.dashscope)
                        Text("Anthropic Claude（美国 · 出境）").tag(VisionSettings.Provider.anthropic)
                    }
                    if VisionSettings.shared.isCrossBorder {
                        Text("⚠️ 选择此项后，拍摄的图片将传至美国服务器，触发个人信息出境合规义务。")
                            .font(.caption).foregroundColor(.danger)
                    }
                    SecureField("API Key", text: $keyText)
                        .onChange(of: keyText) { VisionSettings.shared.apiKey = $0 }
                    TextField("模型名（可选）", text: modelBinding)
                    TextField("BaseURL（可选）", text: baseURLBinding)
                    Toggle("仅本地 / 不上云", isOn: localOnlyBinding)
                    Text("开启后禁用云端 VLM，仅使用本机端侧 MiniCPM-V 4.6 推理（需先到下方「模型管理」下载模型，识别数据不出设备）。")
                        .font(.caption).foregroundColor(.secondary)
                    Button { showPrivacy = true } label: {
                        Label("隐私政策与数据共享说明", systemImage: "hand.raised.fill")
                    }
                }

                Section("端侧 AI 模型（MiniCPM-V 4.6）") {
                    NavigationLink {
                        ModelManagerView()
                    } label: {
                        Label("模型管理（下载 / 加载）", systemImage: "cpu")
                    }
                    Text("图片向量未命中后必须优先运行 MiniCPM-V；模型缺失或内存准入失败时会明确提示，再按配置决定是否使用云端。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("数据备份与恢复（离线）") {
                    Button { doExport() } label: {
                        Label("导出数据包 (JSON)", systemImage: "square.and.arrow.up")
                    }
                    Button { showImport = true } label: {
                        Label("导入数据包 (JSON)", systemImage: "square.and.arrow.down")
                    }
                    Text("导出文件可通过 AirDrop / 微信 发送给其他设备，一键恢复，全程无云端。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("系统诊断与日志") {
                    NavigationLink {
                        DiagnosticLogView()
                    } label: {
                        Label("运行时诊断日志", systemImage: "stethoscope")
                    }
                    Text("包含 AI 识别耗时、相机会话状态、数据库 Save 异常栈及网络 API 状态码，方便一键复制排障。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("关于") {
                    HStack {
                        Text("应用版本")
                        Spacer()
                        Text(AppVersion.displayString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("纯离线通用商品物料库存管理")
                    Text("本地 SQLite 存储 · 零后端依赖 · 需 iOS 17+。支持端侧 MiniCPM-V 4.6 本地推理与可选云端 VLM 兜底，识别数据默认不出设备。")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let m = message {
                    Text(m).font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let url = shareURL { ShareSheet(url: url) }
            }
            .sheet(isPresented: $showImport) {
                ImportPicker { url in doImport(url) }
            }
            .alert("隐私政策与数据共享说明", isPresented: $showPrivacy) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("本 App 默认纯本地运行，不向任何第三方发送数据。仅当你配置并启用「AI 视觉识别」时，拍摄的图片与提示词会发送至你选择的服务商：DashScope（阿里云，数据存储于中国境内）或 Anthropic（数据存储于美国）。我们仅发送识别所需的最小图像与文本，不保留你的 API Key 之外的个人信息。你随时可在设置中关闭该功能。")
            }
        }
    }

    private var providerBinding: Binding<VisionSettings.Provider> {
        Binding(get: { VisionSettings.shared.provider },
                set: { VisionSettings.shared.provider = $0 })
    }
    private var localOnlyBinding: Binding<Bool> {
        Binding(get: { VisionSettings.shared.localOnly },
                set: { VisionSettings.shared.localOnly = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { VisionSettings.shared.modelName ?? "" },
                set: { VisionSettings.shared.modelName = $0.isEmpty ? nil : $0 })
    }
    private var baseURLBinding: Binding<String> {
        Binding(get: { VisionSettings.shared.baseURL ?? "" },
                set: { VisionSettings.shared.baseURL = $0.isEmpty ? nil : $0 })
    }

    private func doExport() {
        do {
            let packet = try ExportImport.exportAll(context: ctx)
            shareURL = try ExportImport.writeToFile(packet)
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func doImport(_ url: URL) {
        do {
            try ExportImport.import(from: url, context: ctx)
            message = "导入完成"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 系统分享面板（AirDrop / 微信 / 存储到文件）
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// JSON 文档选择（从 Files / 微信 导入）
struct ImportPicker: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ImportPicker
        init(_ parent: ImportPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { parent.onPicked(u) }
        }
    }
}
