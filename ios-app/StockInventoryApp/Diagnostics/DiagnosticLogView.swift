//
//  DiagnosticLogView.swift
//  库存管理 App · 端侧诊断排障日志视图
//
//  允许用户或测试人员随时在端侧查阅实时捕获的 AI 引擎、相机会话、
//  数据库存储、网络 API 状态码等完整运行时日志，一键复制排障。
//

import SwiftUI

struct DiagnosticLogView: View {
    @State private var logger = AppLogger.shared
    @State private var selectedCategory: AppLogger.LogItem.Category? = nil
    @State private var copiedToast = false

    private var filteredLogs: [AppLogger.LogItem] {
        guard let cat = selectedCategory else { return logger.logs }
        return logger.logs.filter { $0.category == cat }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── 分类筛选 Bar ─────────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(title: "全部", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(AppLogger.LogItem.Category.allCases, id: \.self) { cat in
                            filterChip(title: cat.rawValue, isSelected: selectedCategory == cat) {
                                selectedCategory = cat
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .background(Color.surface)

                Divider()

                // ── 日志列表 ─────────────────────────────────────
                if filteredLogs.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "text.clipboard")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("暂无诊断日志记录")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(filteredLogs) { item in
                            LogItemRow(item: item)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("运行时诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") {
                        logger.clear()
                    }
                    .disabled(logger.logs.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = logger.exportLogsString()
                        ToastManager.shared.show(message: "已复制诊断日志至剪贴板", tone: .success)
                    } label: {
                        Label("复制日志", systemImage: "doc.on.doc")
                    }
                    .disabled(logger.logs.isEmpty)
                }
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.brand : Color.surface)
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct LogItemRow: View {
    let item: AppLogger.LogItem
    @State private var isExpanded = false

    private var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: item.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.level.icon)
                    .foregroundColor(item.level.color)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("[\(item.category.rawValue)]")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        Text(timeString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(item.level.rawValue)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(item.level.color)
                    }

                    Text(item.message)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
            }

            if let det = item.details, !det.isEmpty {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    HStack {
                        Text(isExpanded ? "收起详细栈信息" : "展开详细栈信息")
                            .font(.caption2)
                            .foregroundColor(.brand)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.brand)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(det)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.vertical, 4)
    }
}
