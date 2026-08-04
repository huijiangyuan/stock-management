import SwiftUI
import SwiftData

struct SKUListView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \RawMaterialSKU.skuName) private var skus: [RawMaterialSKU]
    @State private var search = ""
    @State private var showForm = false

    private var filtered: [RawMaterialSKU] {
        guard !search.isEmpty else { return skus }
        return skus.filter {
            $0.skuName.localizedCaseInsensitiveContains(search) ||
            $0.skuCode.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    EmptyState(title: "暂无商品物料", hint: "点击右上角 + 新增，或拍照/扫码智能建库")
                } else {
                    List {
                        ForEach(filtered) { sku in
                            NavigationLink { SKUDetailView(sku: sku) } label: { SKURow(sku: sku) }
                        }
                        .onDelete { indices in
                            for i in indices { ctx.delete(filtered[i]) }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $search, prompt: "搜索名称或编码")
            .navigationTitle("商品与物料库")
            .toolbar {
                Button { showForm = true } label: { Image(systemName: "plus.circle.fill") }
            }
            .sheet(isPresented: $showForm) { SKUFormView() }
        }
    }
}

struct SKURow: View {
    let sku: RawMaterialSKU
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sku.skuName).font(.headline)
            HStack {
                Text(sku.skuCode).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(sku.categoryName).font(.caption).foregroundColor(.secondary)
            }
            if let base = sku.packagingUnits.first {
                Text("基准单位：\(sku.baseUnit) · 默认规格：\(base.unitName) ×\(AppFormatters.fmt(base.conversionRatio))")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
