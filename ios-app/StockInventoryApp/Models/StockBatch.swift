import Foundation
import SwiftData

/// 库存批次表（Batch Management & FIFO）。对应 DDL: stock_batch
@Model
final class StockBatch {
    @Attribute(.unique) var batchId: String
    @Attribute(.unique) var batchNo: String
    var productionDate: Date?
    var expirationDate: Date?
    var supplierName: String?
    var inboundPrice: Double?
    var createdAt: Date

    var sku: RawMaterialSKU?

    @Relationship(deleteRule: .cascade, inverse: \StockInventory.batch)
    var inventories: [StockInventory]

    init(batchId: String = UUID().uuidString,
         batchNo: String,
         productionDate: Date? = nil,
         expirationDate: Date? = nil,
         supplierName: String? = nil,
         inboundPrice: Double? = nil,
         sku: RawMaterialSKU? = nil) {
        self.batchId = batchId
        self.batchNo = batchNo
        self.productionDate = productionDate
        self.expirationDate = expirationDate
        self.supplierName = supplierName
        self.inboundPrice = inboundPrice
        self.sku = sku
        self.inventories = []
        self.createdAt = Date()
    }
}
