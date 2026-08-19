import SwiftUI
import SwiftData

/// 库存 Tab 统一主视图：支持【实时动态库存】与【商品档案库】双模式无缝切换，彻底消除概念歧义。
struct SKUListView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \RawMaterialSKU.skuName) private var skus: [RawMaterialSKU]
    @State private var search = ""
    @State private var showForm = false
    @State private var viewMode: SKUViewMode = .liveInventory

    enum SKUViewMode: String, CaseIterable, Identifiable {
        case liveInventory = "实时动态库存"
        case catalog = "物料档案库"
        var id: String { rawValue }
    }

    private var filtered: [RawMaterialSKU] {
        guard !search.isEmpty else { return skus }
        return skus.filter {
            $0.skuName.localizedCaseInsensitiveContains(search) ||
            $0.skuCode.localizedCaseInsensitiveContains(search) ||
            $0.categoryName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部视图模式分段切换器
                Picker("视图模式", selection: $viewMode) {
                    ForEach(SKUViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))

                Group {
                    if filtered.isEmpty {
                        EmptyState(
                            title: skus.isEmpty ? "暂无商品物料" : "未找到匹配物料",
                            hint: skus.isEmpty ? "点击右上角 + 新增物料，或拍照 AI 智能建库" : "换个搜索词试试"
                        )
                    } else {
                        List {
                            ForEach(filtered) { sku in
                                NavigationLink {
                                    SKUDetailView(sku: sku)
                                } label: {
                                    if viewMode == .liveInventory {
                                        LiveInventoryRow(sku: sku)
                                    } else {
                                        SKUCatalogRow(sku: sku)
                                    }
                                }
                            }
                            .onDelete { indices in
                                for i in indices { ctx.delete(filtered[i]) }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索物料名称、编码或品类")
            .navigationTitle(viewMode == .liveInventory ? "实时动态库存" : "商品与物料档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showForm = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.brand)
                    }
                }
            }
            .sheet(isPresented: $showForm) { SKUFormView() }
        }
    }
}

/// 实时动态库存行卡片：聚焦实时在库量、多规格折算展示、在库批次与预警状态
struct LiveInventoryRow: View {
    @Environment(\.modelContext) private var ctx
    let sku: RawMaterialSKU

    private var currentTotalBaseQty: Double {
        InventoryStore(context: ctx).totalQty(sku: sku)
    }

    private var inStockBatchCount: Int {
        InventoryStore(context: ctx).fifoBatches(for: sku).count
    }

    private var breakdownText: String {
        InventoryStore.formatMultiUnitBreakdown(sku: sku, totalBaseQty: currentTotalBaseQty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sku.skuName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(sku.skuCode)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(sku.categoryName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                // 库存状态与总数量
                VStack(alignment: .trailing, spacing: 2) {
                    if currentTotalBaseQty == 0 {
                        Text("已缺货")
                            .font(.caption2.bold())
                            .foregroundColor(.danger)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.danger.opacity(0.12))
                            .clipShape(Capsule())
                    } else {
                        Text("\(AppFormatters.fmt(currentTotalBaseQty)) \(sku.baseUnit)")
                            .font(.headline.bold())
                            .foregroundColor(.brand)
                    }
                }
            }

            if currentTotalBaseQty > 0 {
                HStack {
                    Label(breakdownText, systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundColor(.success)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(inStockBatchCount) 个在库批次")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 物料档案行卡片：聚焦基础档案、配置的多级包装规格体系与特征样本
struct SKUCatalogRow: View {
    let sku: RawMaterialSKU

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(sku.skuName)
                    .font(.headline)
                Spacer()
                Text(sku.categoryName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("编码: \(sku.skuCode)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("基准单位: \(sku.baseUnit)")
                    .font(.caption2.bold())
                    .foregroundColor(.brand)
            }

            if !sku.packagingUnits.isEmpty {
                HStack(spacing: 4) {
                    Text("包装规格:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(sku.packagingUnits) { u in
                        Text("\(u.unitName)(×\(AppFormatters.fmt(u.conversionRatio)))")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

typealias SKURow = SKUCatalogRow
