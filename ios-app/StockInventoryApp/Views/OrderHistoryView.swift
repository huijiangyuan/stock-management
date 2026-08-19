import SwiftUI
import SwiftData

/// 单据记录与出入库流水账视图：
/// 支持按【今日/本周/本月/本季度/本年/全部】多时间维度筛选，支持按单据类型过滤，
/// 盘点单高亮展示盘盈盘亏差异，支持一键导出完整 CSV 数据报表。
struct OrderHistoryView: View {
    @Query(sort: \StockOrderHeader.createdAt, order: .reverse) private var orders: [StockOrderHeader]
    @State private var timeRange: TimeRangePreset = .today
    @State private var selectedType: OrderTypeFilter = .all
    @State private var search = ""
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    enum TimeRangePreset: String, CaseIterable, Identifiable {
        case today = "今日"
        case thisWeek = "本周"
        case thisMonth = "本月"
        case thisQuarter = "本季度"
        case thisYear = "本年"
        case all = "全部"
        var id: String { rawValue }

        func matches(date: Date, calendar: Calendar = Calendar.current) -> Bool {
            let now = Date()
            switch self {
            case .all:
                return true
            case .today:
                return calendar.isDate(date, inSameDayAs: now)
            case .thisWeek:
                return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .thisMonth:
                return calendar.isDate(date, equalTo: now, toGranularity: .month)
            case .thisQuarter:
                let m1 = calendar.component(.month, from: date)
                let m2 = calendar.component(.month, from: now)
                let y1 = calendar.component(.year, from: date)
                let y2 = calendar.component(.year, from: now)
                return y1 == y2 && (m1 - 1) / 3 == (m2 - 1) / 3
            case .thisYear:
                return calendar.isDate(date, equalTo: now, toGranularity: .year)
            }
        }
    }

    enum OrderTypeFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case inbound = "入库单"
        case outbound = "出库单"
        case check = "盘点单"
        var id: String { rawValue }

        var typeCode: String? {
            switch self {
            case .all: return nil
            case .inbound: return "INBOUND"
            case .outbound: return "OUTBOUND"
            case .check: return "CHECK"
            }
        }
    }

    private var filteredOrders: [StockOrderHeader] {
        orders.filter { o in
            // 1. 时间范围筛选
            guard timeRange.matches(date: o.createdAt) else { return false }
            // 2. 单据类型筛选
            if let code = selectedType.typeCode, o.orderType != code { return false }
            // 3. 搜索词筛选
            if !search.isEmpty {
                let matchNo = o.orderNo.localizedCaseInsensitiveContains(search)
                let matchItem = o.items.contains { it in
                    (it.sku?.skuName.localizedCaseInsensitiveContains(search) ?? false) ||
                    (it.sku?.skuCode.localizedCaseInsensitiveContains(search) ?? false) ||
                    (it.batch?.batchNo.localizedCaseInsensitiveContains(search) ?? false)
                }
                if !matchNo && !matchItem { return false }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部多维度筛选区
                VStack(spacing: 8) {
                    // 时间范围预设选择器
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TimeRangePreset.allCases) { preset in
                                Button {
                                    timeRange = preset
                                } label: {
                                    Text(preset.rawValue)
                                        .font(.subheadline)
                                        .fontWeight(timeRange == preset ? .bold : .regular)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(timeRange == preset ? Color.brand : Color.surface)
                                        .foregroundColor(timeRange == preset ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // 单据类型分段选择器
                    Picker("单据类型", selection: $selectedType) {
                        ForEach(OrderTypeFilter.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
                .background(Color(.systemBackground))

                Group {
                    if filteredOrders.isEmpty {
                        EmptyState(
                            title: orders.isEmpty ? "暂无单据记录" : "当前筛选条件下无单据",
                            hint: orders.isEmpty ? "在首页快捷入口进行入库、出库或盘点操作" : "尝试切换上方时间范围或单据类型"
                        )
                    } else {
                        List {
                            ForEach(filteredOrders) { o in
                                OrderCardSection(order: o)
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索单号、商品名称或批次号")
            .navigationTitle("单据流水记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        handleExportCSV()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出报表")
                                .font(.subheadline)
                        }
                        .foregroundColor(.brand)
                    }
                    .disabled(filteredOrders.isEmpty)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportURL {
                    ShareSheetView(activityItems: [url])
                }
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }

    private func handleExportCSV() {
        do {
            let url = try ExportImport.exportOrdersCSV(orders: filteredOrders, timeRangeTitle: timeRange.rawValue)
            exportURL = url
            showShareSheet = true
            ToastManager.shared.show(message: "📄 报表生成成功", details: "共导出 \(filteredOrders.count) 笔单据", tone: .success)
        } catch {
            exportErrorMessage = "生成 CSV 报表失败：\(error.localizedDescription)"
            showExportError = true
        }
    }
}

/// 单据卡片展示单元
private struct OrderCardSection: View {
    let order: StockOrderHeader

    private var typeLabel: String {
        order.orderType == "INBOUND" ? "入库单" : order.orderType == "OUTBOUND" ? "出库单" : "盘点单"
    }

    private var typeColor: Color {
        order.orderType == "INBOUND" ? .success : order.orderType == "OUTBOUND" ? .brand : .warning
    }

    private var typeIcon: String {
        order.orderType == "INBOUND" ? "arrow.down.circle.fill" : order.orderType == "OUTBOUND" ? "arrow.up.circle.fill" : "checklist"
    }

    var body: some View {
        Section {
            ForEach(order.items) { it in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(it.sku?.skuName ?? "未知物料")
                            .font(.subheadline.bold())
                        if let u = it.unit {
                            Text("· \(u.unitName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(AppFormatters.fmt(it.totalBaseQty)) \(it.sku?.baseUnit ?? "")")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                    }

                    HStack(spacing: 8) {
                        if let batch = it.batch {
                            Text("批次: \(batch.batchNo)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if let sup = batch.supplierName, !sup.isEmpty {
                                Text("· 供应商: \(sup)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let price = batch.inboundPrice, price > 0 {
                                Text("· 单价: ¥\(AppFormatters.fmt(price))")
                                    .font(.caption2)
                                    .foregroundColor(.brand)
                            }
                        }
                        if it.conversionRatio != 1.0, let u = it.unit {
                            Text("(\(AppFormatters.fmt(it.operatingQty)) \(u.unitName) × \(AppFormatters.fmt(it.conversionRatio)))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if order.orderType == "INBOUND", let price = it.batch?.inboundPrice, price > 0 {
                        let totalCost = price * it.operatingQty
                        HStack {
                            Text("采购总额: ¥\(AppFormatters.fmt(totalCost)) 元")
                                .font(.caption2.bold())
                                .foregroundColor(.brand)
                        }
                    }

                    // 盘点单重点渲染盘前数量与盘盈盘亏差异
                    if order.orderType == "CHECK" {
                        HStack(spacing: 12) {
                            if let orig = it.originalBaseQty {
                                Text("盘前: \(AppFormatters.fmt(orig))\(it.sku?.baseUnit ?? "")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("实盘: \(AppFormatters.fmt(it.totalBaseQty))\(it.sku?.baseUnit ?? "")")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Spacer()

                            if let diff = it.differenceBaseQty {
                                if diff > 0 {
                                    Text("盘盈 +\(AppFormatters.fmt(diff))\(it.sku?.baseUnit ?? "")")
                                        .font(.caption2.bold())
                                        .foregroundColor(.success)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.success.opacity(0.12))
                                        .clipShape(Capsule())
                                } else if diff < 0 {
                                    Text("盘亏 \(AppFormatters.fmt(diff))\(it.sku?.baseUnit ?? "")")
                                        .font(.caption2.bold())
                                        .foregroundColor(.danger)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.danger.opacity(0.12))
                                        .clipShape(Capsule())
                                } else {
                                    Text("账实相符")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)
            }

            if let remark = order.remark, !remark.isEmpty {
                Text("备注：\(remark)").font(.caption2).foregroundColor(.secondary)
            }
        } header: {
            HStack {
                Label(order.orderNo, systemImage: typeIcon)
                    .font(.caption.bold())
                Spacer()
                Text(AppFormatters.dateTime.string(from: order.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(typeLabel)
                    .font(.caption2.bold())
                    .foregroundColor(typeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }
}

/// 原生分享面板桥接
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
