import Foundation
import SwiftData

/// 库存业务核心：多级包装换算、批次 FIFO、单据原子记账、临期/低库存预警。
/// 所有数据仅驻留本地 SQLite（SwiftData），无任何网络依赖。
final class InventoryStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - 单据处理（每单原子写入）

    struct OrderLine {
        let sku: RawMaterialSKU
        let unit: PackagingUnit?
        let batch: StockBatch?
        let operatingQty: Double
        let conversionRatio: Double
        let mode: RecognitionMode
        var note: String? = nil
        var originalBaseQty: Double? = nil
        var differenceBaseQty: Double? = nil
    }

    @discardableResult
    func processOrder(type: String,
                      lines: [OrderLine],
                      location: String = "默认货位",
                      remark: String? = nil) throws -> StockOrderHeader {
        let header = StockOrderHeader(orderNo: Self.makeOrderNo(type: type),
                                      orderType: type, remark: remark)
        context.insert(header)

        for line in lines {
            let totalBase = line.operatingQty * line.conversionRatio
            var originalBase: Double? = nil
            var differenceBase: Double? = nil

            if type == "CHECK" {
                let currentBase = totalQty(location: location, sku: line.sku, batch: line.batch)
                originalBase = line.originalBaseQty ?? currentBase
                differenceBase = totalBase - (originalBase ?? 0)
            }

            let item = StockOrderItem(operatingQty: line.operatingQty,
                                      conversionRatio: line.conversionRatio,
                                      totalBaseQty: totalBase,
                                      recognitionMode: line.mode.rawValue,
                                      confidenceScore: nil,
                                      note: line.note,
                                      originalBaseQty: originalBase,
                                      differenceBaseQty: differenceBase,
                                      header: header,
                                      sku: line.sku,
                                      unit: line.unit,
                                      batch: line.batch)
            context.insert(item)
            try applyToInventory(type: type, sku: line.sku, batch: line.batch,
                                 qty: totalBase, location: location)
        }
        try context.save()
        return header
    }

    private func applyToInventory(type: String, sku: RawMaterialSKU,
                                  batch: StockBatch?, qty: Double,
                                  location: String) throws {
        let inv = fetchOrCreateInventory(location: location, sku: sku, batch: batch)
        switch type {
        case "INBOUND":
            inv.qtyBaseUnit += qty
        case "OUTBOUND":
            inv.qtyBaseUnit = max(0, inv.qtyBaseUnit - qty)
        case "CHECK":
            inv.qtyBaseUnit = qty
        default:
            break
        }
        inv.updatedAt = Date()
    }

    private func fetchOrCreateInventory(location: String, sku: RawMaterialSKU,
                                        batch: StockBatch?) -> StockInventory {
        if let existing = sku.inventories.first(where: {
            $0.locationName == location && $0.batch?.batchId == batch?.batchId
        }) {
            return existing
        }
        let inv = StockInventory(locationName: location, sku: sku, batch: batch)
        context.insert(inv)
        return inv
    }

    // MARK: - 批次先进先出（FIFO）推荐

    func fifoBatches(for sku: RawMaterialSKU, location: String? = nil) -> [StockBatch] {
        let inStock = sku.batches.filter { batch in
            let qty = totalQty(location: location, sku: sku, batch: batch)
            return qty > 0
        }
        return inStock.sorted {
            ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture)
        }
    }

    func totalQty(location: String? = nil, sku: RawMaterialSKU, batch: StockBatch? = nil) -> Double {
        sku.inventories
            .filter { (location == nil || $0.locationName == location) &&
                      (batch == nil || $0.batch?.batchId == batch?.batchId) }
            .reduce(0) { $0 + $1.qtyBaseUnit }
    }

    // MARK: - 临期预警（打开 App 时扫描）

    func expiringSoon(withinDays: Int = 3) -> [(sku: RawMaterialSKU, batch: StockBatch, daysLeft: Int, qty: Double)] {
        let now = Date()
        let cal = Calendar.current
        var result: [(RawMaterialSKU, StockBatch, Int, Double)] = []
        let descriptor = FetchDescriptor<StockInventory>(predicate: #Predicate { $0.qtyBaseUnit > 0 })
        guard let invs = try? context.fetch(descriptor) else { return result }
        for inv in invs {
            guard let batch = inv.batch, let exp = batch.expirationDate, let sku = inv.sku else { continue }
            let days = cal.dateComponents([.day], from: now, to: exp).day ?? 0
            if days <= withinDays {
                result.append((sku, batch, days, inv.qtyBaseUnit))
            }
        }
        return result.sorted { $0.2 < $1.2 }
    }

    // MARK: - 低库存预警

    func lowStock(thresholdFor: (RawMaterialSKU) -> Double) -> [(sku: RawMaterialSKU, qty: Double)] {
        let descriptor = FetchDescriptor<RawMaterialSKU>()
        guard let skus = try? context.fetch(descriptor) else { return [] }
        return skus.compactMap { sku in
            let qty = totalQty(sku: sku)
            return qty < thresholdFor(sku) ? (sku, qty) : nil
        }
    }

    /// 缺货：存在库存记录但剩余为 0 的 SKU
    func outOfStock() -> [RawMaterialSKU] {
        let descriptor = FetchDescriptor<StockInventory>(predicate: #Predicate { $0.qtyBaseUnit == 0 })
        guard let invs = try? context.fetch(descriptor) else { return [] }
        return Array(Set(invs.compactMap { $0.sku }))
    }

    // MARK: - 单据号生成

    static func makeOrderNo(type: String) -> String {
        let prefix = type == "INBOUND" ? "IN" : type == "OUTBOUND" ? "OUT" : "CK"
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let seq = abs(Int(Date().timeIntervalSince1970)) % 100000
        return "\(prefix)-\(df.string(from: Date()))-\(String(format: "%05d", seq))"
    }

    // MARK: - 学习模式：本地建库（新增 SKU / 规格 / 特征样本）

    @discardableResult
    func learnSKU(code: String, name: String, category: String,
                  baseUnit: String = "包", shelfLifeDays: Int = 0,
                  unitName: String = "散包", conversionRatio: Double = 1.0,
                  imagePath: String? = nil, ocrText: String? = nil) -> RawMaterialSKU {
        let sku = RawMaterialSKU(skuCode: code, skuName: name, categoryName: category,
                                 baseUnit: baseUnit, shelfLifeDays: shelfLifeDays)
        context.insert(sku)
        let unit = PackagingUnit(unitName: unitName, unitType: "BASE",
                                 conversionRatio: conversionRatio, sku: sku)
        context.insert(unit)
        if imagePath != nil || ocrText != nil {
            let sample = FeatureSample(angleTag: "FRONT", ocrTextContent: ocrText,
                                       sampleImagePath: imagePath, unit: unit, sku: sku)
            context.insert(sample)
        }
        try? context.save()
        return sku
    }

    // MARK: - 多规格折算与展示辅助

    /// 将以 baseUnit 计量的总数量智能换算为多级包装组合显示
    /// 例如：总数 125 瓶，规格含「箱(×24)」，则输出「5 箱 + 5 瓶」
    static func formatMultiUnitBreakdown(sku: RawMaterialSKU, totalBaseQty: Double) -> String {
        guard totalBaseQty > 0 else { return "0 \(sku.baseUnit)" }
        let validUnits = sku.packagingUnits
            .filter { $0.conversionRatio > 1.0 }
            .sorted { $0.conversionRatio > $1.conversionRatio }

        guard let largest = validUnits.first else {
            return "\(AppFormatters.fmt(totalBaseQty)) \(sku.baseUnit)"
        }

        let ratio = largest.conversionRatio
        let whole = Int(totalBaseQty / ratio)
        let remainder = totalBaseQty.truncatingRemainder(dividingBy: ratio)

        if whole > 0 && remainder > 0 {
            return "\(whole) \(largest.unitName) + \(AppFormatters.fmt(remainder)) \(sku.baseUnit)"
        } else if whole > 0 && remainder == 0 {
            return "\(whole) \(largest.unitName)"
        } else {
            return "\(AppFormatters.fmt(totalBaseQty)) \(sku.baseUnit)"
        }
    }
}
