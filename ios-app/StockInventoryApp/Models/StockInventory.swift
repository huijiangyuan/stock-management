import Foundation
import SwiftData

/// 实时库存台账汇总表（按 货位 + SKU + 批次 维度汇总）。对应 DDL: stock_inventory
@Model
final class StockInventory {
    @Attribute(.unique) var inventoryId: String
    var locationName: String
    var qtyBaseUnit: Double         // 当前剩余总数量（以 base_unit 计）
    var updatedAt: Date

    var sku: RawMaterialSKU?
    var batch: StockBatch?

    init(inventoryId: String = UUID().uuidString,
         locationName: String = "默认货位",
         qtyBaseUnit: Double = 0,
         sku: RawMaterialSKU? = nil,
         batch: StockBatch? = nil) {
        self.inventoryId = inventoryId
        self.locationName = locationName
        self.qtyBaseUnit = qtyBaseUnit
        self.sku = sku
        self.batch = batch
        self.updatedAt = Date()
    }
}
