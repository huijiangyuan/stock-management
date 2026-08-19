import Foundation
import SwiftData

/// SKU 多级包装规格表（散包 / 中箱 / 大箱 / 托盘无限扩展）。对应 DDL: sku_packaging_unit
@Model
final class PackagingUnit {
    @Attribute(.unique) var unitId: String
    var unitName: String
    var unitType: String           // BASE / MID / LARGE / PALLET
    var conversionRatio: Double     // 对应 base_unit 的换算比例
    var barcode: String?

    var sku: RawMaterialSKU?

    @Relationship(deleteRule: .cascade, inverse: \FeatureSample.unit)
    var featureSamples: [FeatureSample]

    init(unitId: String = UUID().uuidString,
         unitName: String,
         unitType: String = "BASE",
         conversionRatio: Double,
         barcode: String? = nil,
         sku: RawMaterialSKU? = nil) {
        self.unitId = unitId
        self.unitName = unitName
        self.unitType = unitType
        self.conversionRatio = conversionRatio
        self.barcode = barcode
        self.sku = sku
        self.featureSamples = []
    }
}
