import Foundation
import SwiftData

/// 原材料标准 SKU 主表（核心主数据）。对应方案文档 DDL: raw_material_sku
@Model
final class RawMaterialSKU {
    @Attribute(.unique) var skuId: String
    @Attribute(.unique) var skuCode: String
    var skuName: String
    var categoryName: String
    var baseUnit: String
    var shelfLifeDays: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PackagingUnit.sku)
    var packagingUnits: [PackagingUnit]

    @Relationship(deleteRule: .cascade, inverse: \StockBatch.sku)
    var batches: [StockBatch]

    @Relationship(deleteRule: .cascade, inverse: \FeatureSample.sku)
    var featureSamples: [FeatureSample]

    @Relationship(deleteRule: .cascade, inverse: \StockInventory.sku)
    var inventories: [StockInventory]

    init(skuId: String = UUID().uuidString,
         skuCode: String,
         skuName: String,
         categoryName: String,
         baseUnit: String = "包",
         shelfLifeDays: Int = 0) {
        self.skuId = skuId
        self.skuCode = skuCode
        self.skuName = skuName
        self.categoryName = categoryName
        self.baseUnit = baseUnit
        self.shelfLifeDays = shelfLifeDays
        self.createdAt = Date()
        self.packagingUnits = []
        self.batches = []
        self.featureSamples = []
        self.inventories = []
    }
}
