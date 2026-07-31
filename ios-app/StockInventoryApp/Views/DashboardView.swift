import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \RawMaterialSKU.createdAt, order: .reverse) private var skus: [RawMaterialSKU]

    @State private var expiring: [(RawMaterialSKU, StockBatch, Int, Double)] = []
    @State private var outOfStock: [RawMaterialSKU] = []
    @State private var showOrder: DashOrderPreset? = nil

    enum DashOrderPreset: Identifiable {
        case inbound, outbound, check
        var id: String { String(describing: self) }
        var type: String {
            switch self { case .inbound: return "INBOUND"; case .outbound: return "OUTBOUND"; case .check: return "CHECK" }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !expiring.isEmpty {
                        BannerView(tone: .warning,
                                   message: "\(expiring.count) 种原材料将在 3 天内过期，请优先出库")
                    }
                    if !outOfStock.isEmpty {
                        BannerView(tone: .danger,
                                   message: "\(outOfStock.count) 种原材料已缺货，请及时补货")
                    }

                    HStack(spacing: 10) {
                        quickAction("入库", .success, "arrow.down.doc.fill") { showOrder = .inbound }
                        quickAction("出库", .brand, "arrow.up.doc.fill") { showOrder = .outbound }
                        quickAction("盘点", .warning, "checklist") { showOrder = .check }
                    }

                    AppCard {
                        HStack {
                            stat("原材料", "\(skus.count)")
                            Divider()
                            stat("临期", "\(expiring.count)")
                            Divider()
                            stat("缺货", "\(outOfStock.count)")
                        }
                    }

                    if !expiring.isEmpty {
                        AppCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("临期明细").font(.headline)
                                ForEach(expiring, id: \.1.batchId) { item in
                                    HStack {
                                        Text(item.0.skuName).font(.subheadline)
                                        Spacer()
                                        Text("\(item.2) 天 · \(AppFormatters.fmt(item.3))\(item.0.baseUnit)")
                                            .font(.subheadline).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .navigationTitle("库存总览")
            .sheet(item: $showOrder) { p in OrderCreateView(presetType: p.type) }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        let store = InventoryStore(context: ctx)
        expiring = store.expiringSoon(withinDays: 3)
        outOfStock = store.outOfStock()
    }

    private func quickAction(_ title: String, _ color: Color, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.subheadline)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundColor(color)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.bold())
            Text(k).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
