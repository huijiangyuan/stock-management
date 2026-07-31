import SwiftUI
import SwiftData

/// 出入库 / 盘点 单据创建。支持扫码（条码引擎）与手动两种识别来源，
/// 自动完成 多级包装 → 基准单位 换算，并按批次 FIFO 给出出库建议。
struct OrderCreateView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    var presetSKU: RawMaterialSKU?
    var presetType: String

    @State private var orderType: String
    @State private var selectedSKU: RawMaterialSKU?
    @State private var selectedUnit: PackagingUnit?
    @State private var qtyText = "1"
    @State private var location = "默认货位"

    @State private var showSKUPicker = false
    @State private var showScanner = false
    @State private var showLearn = false
    @State private var learnBarcode: String? = nil
    @State private var lastMode: RecognitionMode = .manual

    // 入库批次字段
    @State private var batchNo = ""
    @State private var productionDate = Date()
    @State private var expirationDate = Date()
    @State private var supplier = ""
    @State private var inboundPrice = ""
    // 出库/盘点批次选择
    @State private var selectedBatch: StockBatch?
    @State private var showFIFOAlert = false
    @State private var pendingBatch: StockBatch? = nil
    @State private var fifoOverrideNote: String? = nil

    init(presetSKU: RawMaterialSKU? = nil, presetType: String = "INBOUND") {
        self.presetSKU = presetSKU
        self.presetType = presetType
        _orderType = State(initialValue: presetType)
        _selectedSKU = State(initialValue: presetSKU)
        _selectedUnit = State(initialValue: presetSKU?.packagingUnits.first)
    }

    private var totalBase: Double {
        guard let u = selectedUnit, let q = Double(qtyText) else { return 0 }
        return q * u.conversionRatio
    }

    private var inStockBatches: [StockBatch] {
        guard let sku = selectedSKU else { return [] }
        return InventoryStore(context: ctx).fifoBatches(for: sku)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("单据类型") {
                    Picker("类型", selection: $orderType) {
                        Text("入库").tag("INBOUND")
                        Text("出库").tag("OUTBOUND")
                        Text("盘点").tag("CHECK")
                    }
                    .pickerStyle(.segmented)
                    .disabled(presetSKU != nil)
                }

                Section("原材料") {
                    if let sku = selectedSKU {
                        HStack {
                            Text(sku.skuName).font(.headline)
                            Spacer()
                            Button("重选") { showSKUPicker = true }
                        }
                        if let u = selectedUnit {
                            Picker("规格", selection: $selectedUnit) {
                                ForEach(sku.packagingUnits) { unit in
                                    Text("\(unit.unitName) ×\(AppFormatters.fmt(unit.conversionRatio))").tag(unit as PackagingUnit?)
                                }
                            }
                        }
                    } else {
                        Button("选择原材料 / 扫码") { showSKUPicker = true }
                    }
                    Button { showScanner = true } label: {
                        Label("扫码识别", systemImage: "barcode.viewfinder")
                    }
                }

                if selectedSKU != nil {
                    Section("数量") {
                        HStack {
                            TextField("操作数量", text: $qtyText).keyboardType(.decimalPad)
                            if let u = selectedUnit {
                                Text(u.unitName).foregroundColor(.secondary)
                            }
                        }
                        if let u = selectedUnit {
                            Text("换算为 \(AppFormatters.fmt(totalBase)) \(selectedSKU?.baseUnit ?? "包")")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }

                    Section("货位") {
                        TextField("货位名称", text: $location)
                    }

                    if orderType == "INBOUND" {
                        Section("新建批次") {
                            TextField("批次号（留空自动生成）", text: $batchNo)
                            DatePicker("生产日期", selection: $productionDate, displayedComponents: .date)
                            DatePicker("到期日期", selection: $expirationDate, displayedComponents: .date)
                            TextField("供应商", text: $supplier)
                            TextField("入库单价", text: $inboundPrice).keyboardType(.decimalPad)
                        }
                    } else {
                        batchSection
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                Button("取消") { dismiss() }
                Button("生成单据") { submit(); dismiss() }.disabled(!canSubmit)
            }
            .sheet(isPresented: $showSKUPicker) { SKUPickerSheet(selected: $selectedSKU) }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { code in handleScanned(code) }
            }
            .sheet(isPresented: $showLearn) {
                SKUFormView(initialBarcode: learnBarcode)
            }
            .alert("FIFO 覆盖确认", isPresented: $showFIFOAlert) {
                Button("取消", role: .cancel) {
                    selectedBatch = inStockBatches.first
                    pendingBatch = nil
                }
                Button("确认覆盖") {
                    if let chosen = pendingBatch {
                        selectedBatch = chosen
                        let skipped = inStockBatches.prefix(while: { $0.batchId != chosen.batchId })
                                              .map { $0.batchNo }
                        let iso = ISO8601DateFormatter().string(from: Date())
                        fifoOverrideNote = "FIFO覆盖：跳过批次[\(skipped.joined(separator: ","))]，时间\(iso)"
                    }
                    pendingBatch = nil
                }
            } message: {
                let skipped = inStockBatches.prefix(while: { $0.batchId != (pendingBatch?.batchId ?? "") })
                                          .map { $0.batchNo }
                Text("所选批次并非最早可出库批次，将跳过更早批次：\(skipped.joined(separator: "、"))。是否仍按该批次出库？")
            }
        }
    }

    private var title: String {
        orderType == "INBOUND" ? "入库单" : orderType == "OUTBOUND" ? "出库单" : "盘点单"
    }

    private var canSubmit: Bool {
        guard let _ = selectedSKU, let _ = selectedUnit, Double(qtyText) ?? 0 > 0 else { return false }
        if orderType != "INBOUND" && inStockBatches.isEmpty { return false }
        return true
    }

    /// 出库 / 盘点时按 FIFO 选择批次：最早批次可直接选，非最早需二次确认覆盖。
    private var batchSection: some View {
        Section("选择批次（FIFO 优先）") {
            if inStockBatches.isEmpty {
                Text("无可用批次").foregroundColor(.secondary)
            } else {
                ForEach(inStockBatches) { batch in
                    Button {
                        if inStockBatches.first?.batchId == batch.batchId {
                            selectedBatch = batch
                        } else {
                            pendingBatch = batch
                            showFIFOAlert = true
                        }
                    } label: {
                        BatchPickRow(batch: batch,
                                     selected: selectedBatch?.batchId == batch.batchId,
                                     isEarliest: inStockBatches.first?.batchId == batch.batchId)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func handleScanned(_ code: String) {
        lastMode = .barcode
        let result = BarcodeEngine().recognize(RecognitionInput(barcode: code), context: ctx)
        if let sku = result.sku {
            selectedSKU = sku
            selectedUnit = result.packagingUnit ?? sku.packagingUnits.first
        } else {
            learnBarcode = code
            showLearn = true
        }
    }

    private func submit() {
        guard let sku = selectedSKU, let unit = selectedUnit,
              let qty = Double(qtyText), qty > 0 else { return }
        let store = InventoryStore(context: ctx)

        var batch: StockBatch? = nil
        if orderType == "INBOUND" {
            let newBatch = StockBatch(batchNo: batchNo.isEmpty ? Self.autoBatchNo(sku) : batchNo,
                               productionDate: productionDate, expirationDate: expirationDate,
                               supplierName: supplier.isEmpty ? nil : supplier,
                               inboundPrice: Double(inboundPrice), sku: sku)
            ctx.insert(newBatch)
            batch = newBatch
        } else {
            batch = selectedBatch
        }

        let line = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batch,
                                            operatingQty: qty, conversionRatio: unit.conversionRatio,
                                            mode: lastMode, note: fifoOverrideNote)
        try? store.processOrder(type: orderType, lines: [line], location: location)
    }

    static func autoBatchNo(_ sku: RawMaterialSKU) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let r = Int.random(in: 1...99)
        return "\(sku.skuCode)-\(df.string(from: Date()))-\(String(format: "%02d", r))"
    }
}

struct BatchPickRow: View {
    let batch: StockBatch
    let selected: Bool
    let isEarliest: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(batch.batchNo).font(.subheadline)
                    if isEarliest {
                        Text("最早")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.warning)
                            .clipShape(Capsule())
                    }
                }
                if let exp = batch.expirationDate {
                    Text("到期 \(AppFormatters.date.string(from: exp))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(.brand) }
        }
    }
}

/// SKU 选择浮层（可搜索）
struct SKUPickerSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RawMaterialSKU.skuName) private var skus: [RawMaterialSKU]
    @State private var search = ""
    @Binding var selected: RawMaterialSKU?

    var body: some View {
        NavigationStack {
            List {
                ForEach(skus.filter {
                    search.isEmpty || $0.skuName.localizedCaseInsensitiveContains(search)
                        || $0.skuCode.localizedCaseInsensitiveContains(search)
                }) { sku in
                    Button { selected = sku; dismiss() } label: { SKURow(sku: sku) }
                }
            }
            .searchable(text: $search, prompt: "搜索名称或编码")
            .navigationTitle("选择原材料")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}
