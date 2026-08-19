import Foundation
import SwiftData

/// 出入库与盘点单据头表。对应 DDL: stock_order_header
@Model
final class StockOrderHeader {
    @Attribute(.unique) var orderId: String
    @Attribute(.unique) var orderNo: String
    var orderType: String            // INBOUND / OUTBOUND / CHECK
    var locationName: String?        // 所属仓库/货位名称
    var remark: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \StockOrderItem.header)
    var items: [StockOrderItem]

    init(orderId: String = UUID().uuidString,
         orderNo: String,
         orderType: String,
         locationName: String? = "默认仓库",
         remark: String? = nil) {
        self.orderId = orderId
        self.orderNo = orderNo
        self.orderType = orderType
        self.locationName = locationName
        self.remark = remark
        self.createdAt = Date()
        self.items = []
    }
}
