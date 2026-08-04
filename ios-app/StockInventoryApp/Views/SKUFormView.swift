import SwiftUI
import SwiftData

/// 新增 / 编辑 SKU，并维护其多级包装规格。学习模式（扫到未知条码/AI 识别新品）也走此表单。
struct SKUFormView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    var editing: RawMaterialSKU?
    var initialBarcode: String? = nil
    /// AI 识别后预填的商品名称（新品登记快速通道）
    var initialName: String? = nil

    @State private var skuCode = ""
    @State private var skuName = ""
    @State private var categoryName = ""
    @State private var baseUnit = "包"
    @State private var shelfLifeDays = "0"
    @State private var units: [PackagingUnitDraft] = []

    struct PackagingUnitDraft: Identifiable {
        var id = UUID().uuidString
        var unitId: String? = nil
        var unitName: String
        var unitType: String
        var conversionRatio: String
        var barcode: String = ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("商品编码（如 SKU-1001）", text: $skuCode)
                    TextField("商品名称（如 精品肥牛卷）", text: $skuName)
                    TextField("品类（如 肉类/冻品）", text: $categoryName)
                    TextField("基准单位", text: $baseUnit)
                    TextField("标准保质期（天）", text: $shelfLifeDays)
                        .keyboardType(.numberPad)
                }
                Section("多级包装规格") {
                    ForEach($units) { $u in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("规格名（散包/中箱/大箱）", text: $u.unitName)
                                Picker("类型", selection: $u.unitType) {
                                    Text("BASE").tag("BASE")
                                    Text("MID").tag("MID")
                                    Text("LARGE").tag("LARGE")
                                    Text("PALLET").tag("PALLET")
                                }
                                .frame(width: 110)
                            }
                            HStack {
                                TextField("换算系数（×基准单位）", text: $u.conversionRatio)
                                    .keyboardType(.decimalPad)
                                TextField("条码（可选）", text: $u.barcode)
                            }
                        }
                    }
                    .onDelete { units.remove(atOffsets: $0) }
                    Button("添加规格") {
                        units.append(PackagingUnitDraft(unitName: "", unitType: "BASE", conversionRatio: "1"))
                    }
                }
            }
            .navigationTitle(editing == nil ? "新增原材料" : "编辑原材料")
            .toolbar {
                Button("取消") { dismiss() }
                Button("保存") { save(); dismiss() }.disabled(!canSave)
            }
            .onAppear(perform: loadIfEditing)
        }
    }

    private var canSave: Bool {
        !skuCode.isEmpty && !skuName.isEmpty && !units.isEmpty &&
        units.allSatisfy { !$0.unitName.isEmpty && Double($0.conversionRatio) != nil }
    }

    private func loadIfEditing() {
        guard let s = editing else {
            var base = PackagingUnitDraft(unitName: "散包", unitType: "BASE", conversionRatio: "1")
            if let bc = initialBarcode { base.barcode = bc }
            units = [base]
            // AI 识别新品登记：预填名称
            if let name = initialName { skuName = name }
            return
        }
        skuCode = s.skuCode; skuName = s.skuName; categoryName = s.categoryName
        baseUnit = s.baseUnit; shelfLifeDays = "\(s.shelfLifeDays)"
        units = s.packagingUnits.map {
            PackagingUnitDraft(unitId: $0.unitId, unitName: $0.unitName, unitType: $0.unitType,
                               conversionRatio: "\($0.conversionRatio)", barcode: $0.barcode ?? "")
        }
    }

    private func save() {
        let ratio: Double = Double(shelfLifeDays) ?? 0
        let store = InventoryStore(context: ctx)

        let target: RawMaterialSKU
        if let s = editing {
            s.skuCode = skuCode; s.skuName = skuName; s.categoryName = categoryName
            s.baseUnit = baseUnit; s.shelfLifeDays = Int(ratio)
            target = s
        } else {
            target = RawMaterialSKU(skuCode: skuCode, skuName: skuName,
                                    categoryName: categoryName, baseUnit: baseUnit,
                                    shelfLifeDays: Int(ratio))
            ctx.insert(target)
        }

        // 同步包装规格（按 unitId 命中等幂）
        let existingIds = Set(target.packagingUnits.map { $0.unitId })
        for u in units {
            guard let cr = Double(u.conversionRatio) else { continue }
            if let id = u.unitId, existingIds.contains(id),
               let exist = target.packagingUnits.first(where: { $0.unitId == id }) {
                exist.unitName = u.unitName; exist.unitType = u.unitType
                exist.conversionRatio = cr; exist.barcode = u.barcode.isEmpty ? nil : u.barcode
            } else {
                let pu = PackagingUnit(unitName: u.unitName, unitType: u.unitType,
                                       conversionRatio: cr, barcode: u.barcode.isEmpty ? nil : u.barcode,
                                       sku: target)
                ctx.insert(pu)
            }
        }
        try? ctx.save()
        _ = store
    }
}
