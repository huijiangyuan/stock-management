import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var ctx
    @State private var shareURL: URL?
    @State private var showImport = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
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
                Section("关于") {
                    Text("纯离线餐饮原材料库存管理")
                    Text("本地 SQLite 存储 · 零后端依赖 · 需 iOS 17+")
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
        }
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
