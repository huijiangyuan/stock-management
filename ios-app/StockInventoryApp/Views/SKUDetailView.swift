import SwiftUI
import SwiftData

struct SKUDetailView: View {
    @Environment(\.modelContext) private var ctx
    let sku: RawMaterialSKU

    @State private var showOrder: OrderPreset? = nil
    @State private var showForm = false
    @State private var fifo: [StockBatch] = []
    @State private var inventories: [StockInventory] = []

    enum OrderPreset: Identifiable {
        case inbound, outbound, check
        var id: String { String(describing: self) }
        var type: String {
            switch self { case .inbound: return "INBOUND"; case .outbound: return "OUTBOUND"; case .check: return "CHECK" }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                AppCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sku.skuName).font(.title3.bold())
                        line("编码", sku.skuCode)
                        line("品类", sku.categoryName)
                        line("基准单位", sku.baseUnit)
                        line("标准保质期", "\(sku.shelfLifeDays) 天")
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("多级包装规格").font(.headline)
                        ForEach(sku.packagingUnits) { u in
                            HStack {
                                Text(u.unitName)
                                Spacer()
                                Text("×\(AppFormatters.fmt(u.conversionRatio)) \(sku.baseUnit)")
                                    .foregroundColor(.secondary)
                                if let b = u.barcode { Text("| \(b)").font(.caption2).foregroundColor(.secondary) }
                            }
                            .font(.subheadline)
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("实时库存台账").font(.headline)
                        if inventories.isEmpty {
                            Text("暂无库存").font(.subheadline).foregroundColor(.secondary)
                        }
                        ForEach(inventories) { inv in
                            HStack {
                                Text(inv.locationName)
                                if let b = inv.batch { Text("· \(b.batchNo)").foregroundColor(.secondary) }
                                Spacer()
                                Text("\(AppFormatters.fmt(inv.qtyBaseUnit)) \(sku.baseUnit)")
                                    .bold()
                            }
                            .font(.subheadline)
                        }
                    }
                }

                if let first = fifo.first {
                    BannerView(tone: .warning,
                               message: "系统已按 FIFO 预选最早批次")
                }

                HStack(spacing: 10) {
                    PrimaryButton(title: "入库") { showOrder = .inbound }
                    PrimaryButton(title: "出库") { showOrder = .outbound }
                    Button { showOrder = .check } label: {
                        Text("盘点").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.vertical, 8)
                            .background(Color.warning)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(14)
        }
        .navigationTitle(sku.skuName)
        .toolbar { Button("编辑") { showForm = true } }
        .sheet(item: $showOrder) { preset in
            OrderCreateView(presetSKU: sku, presetType: preset.type)
        }
        .sheet(isPresented: $showForm) { SKUFormView(editing: sku) }
        .onAppear(perform: refresh)
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v)
        }
        .font(.subheadline)
    }

    private func daysLeft(_ b: StockBatch) -> Int {
        guard let exp = b.expirationDate else { return -1 }
        return Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? -1
    }

    private func refresh() {
        fifo = InventoryStore(context: ctx).fifoBatches(for: sku)
        inventories = sku.inventories
    }
}
