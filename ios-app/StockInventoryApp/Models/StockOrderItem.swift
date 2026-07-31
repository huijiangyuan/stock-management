import Foundation
import SwiftData

/// 出入库与盘点单据明细表。对应 DDL: stock_order_item
@Model
final class StockOrderItem {
    var itemId: String
    var operatingQty: Double        // 操作规格数量（例如 2 大箱）
    var conversionRatio: Double     // 换算比例（50）
    var totalBaseQty: Double        // 换算后基准数量（100）
    var recognitionMode: String?    // BARCODE / MANUAL
    var confidenceScore: Double?
    var note: String?               // 备注（可选，如 FIFO 覆盖说明）

    var header: StockOrderHeader?
    var sku: RawMaterialSKU?
    var unit: PackagingUnit?
    var batch: StockBatch?

    init(itemId: String = UUID().uuidString,
         operatingQty: Double,
         conversionRatio: Double,
         totalBaseQty: Double,
         recognitionMode: String? = nil,
         confidenceScore: Double? = nil,
         note: String? = nil,
         header: StockOrderHeader? = nil,
         sku: RawMaterialSKU? = nil,
         unit: PackagingUnit? = nil,
         batch: StockBatch? = nil) {
        self.itemId = itemId
        self.operatingQty = operatingQty
        self.conversionRatio = conversionRatio
        self.totalBaseQty = totalBaseQty
        self.recognitionMode = recognitionMode
        self.confidenceScore = confidenceScore
        self.note = note
        self.header = header
        self.sku = sku
        self.unit = unit
        self.batch = batch
    }
}
