import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \RawMaterialSKU.createdAt, order: .reverse) private var skus: [RawMaterialSKU]

    @State private var expiring: [(RawMaterialSKU, StockBatch, Int, Double)] = []
    @State private var outOfStock: [RawMaterialSKU] = []
    @State private var valuation = InventoryStore.StockValuationSummary(totalValue: 0, valuedSKUCount: 0, totalSKUCount: 0, totalItemCount: 0, topValuedItems: [])
    @State private var showOrder: DashOrderPreset? = nil
    @State private var showWarehousePicker = false
    @State private var warehouseStore = WarehouseStore.shared

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
                                   message: "\(expiring.count) 种商品将在 3 天内到期，请优先出库")
                    }
                    if !outOfStock.isEmpty {
                        BannerView(tone: .danger,
                                   message: "\(outOfStock.count) 种商品已缺货，请及时补货")
                    }

                    // ── 货物价值估算总览 ─────────────────────────────
                    AppCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("货物价值估算", systemImage: "yensign.circle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.brand)
                                Spacer()
                                Text(warehouseStore.currentWarehouse)
                                    .font(.caption2.bold())
                                    .foregroundColor(.brand)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.brand.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("¥")
                                    .font(.title2.bold())
                                    .foregroundColor(.brand)
                                Text(AppFormatters.fmt(valuation.totalValue))
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundColor(.primary)
                                Text("元")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("在库总件数")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(AppFormatters.fmt(valuation.totalItemCount))")
                                        .font(.subheadline.bold())
                                }
                                Spacer()
                                VStack(alignment: .center, spacing: 2) {
                                    Text("已定价物料")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(valuation.valuedSKUCount) / \(valuation.totalSKUCount) 种")
                                        .font(.subheadline.bold())
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("已建档物料")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(skus.count) 种")
                                        .font(.subheadline.bold())
                                }
                            }

                            if valuation.totalSKUCount > 0 && valuation.valuedSKUCount < valuation.totalSKUCount {
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("注：部分商品未填入库单价，入库时登记单价可精准核算总值")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }

                    // ── 快捷出入库操作 ─────────────────────────────
                    HStack(spacing: 10) {
                        quickAction("入库", .success, "arrow.down.doc.fill") { showOrder = .inbound }
                        quickAction("出库", .brand, "arrow.up.doc.fill") { showOrder = .outbound }
                        quickAction("盘点", .warning, "checklist") { showOrder = .check }
                    }

                    // ── 核心指标卡 ─────────────────────────────────
                    AppCard {
                        HStack {
                            stat("商品物料", "\(skus.count)")
                            Divider()
                            stat("临期", "\(expiring.count)")
                            Divider()
                            stat("缺货", "\(outOfStock.count)")
                        }
                    }

                    // ── 高价值货物排行 ─────────────────────────────
                    if !valuation.topValuedItems.isEmpty {
                        AppCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("高货值商品分布", systemImage: "chart.bar.fill")
                                        .font(.headline)
                                    Spacer()
                                }
                                ForEach(valuation.topValuedItems, id: \.sku.skuId) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.sku.skuName)
                                                .font(.subheadline.bold())
                                            Text("库存: \(AppFormatters.fmt(item.qty)) \(item.sku.baseUnit)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text("¥\(AppFormatters.fmt(item.value))")
                                            .font(.subheadline.bold())
                                            .foregroundColor(.brand)
                                    }
                                    if item.sku.skuId != valuation.topValuedItems.last?.sku.skuId {
                                        Divider()
                                    }
                                }
                            }
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

                    Text("StockManager \(AppVersion.displayString)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(14)
            }
            .navigationTitle("库存总览")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showWarehousePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "building.2.crop.circle.fill")
                                .font(.subheadline)
                            Text(warehouseStore.currentWarehouse)
                                .font(.subheadline.bold())
                            Image(systemName: "chevron.down")
                                .font(.caption2.bold())
                        }
                        .foregroundColor(.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.brand.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
            }
            .sheet(item: $showOrder) { p in
                OrderCreateView(presetType: p.type, presetLocation: warehouseStore.currentWarehouse)
            }
            .sheet(isPresented: $showWarehousePicker) {
                WarehousePickerSheet {
                    refresh()
                }
            }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        let store = InventoryStore(context: ctx)
        let loc = warehouseStore.currentWarehouse
        expiring = store.expiringSoon(withinDays: 3, location: loc)
        outOfStock = store.outOfStock(location: loc)
        valuation = store.calculateTotalValuation(location: loc)
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
