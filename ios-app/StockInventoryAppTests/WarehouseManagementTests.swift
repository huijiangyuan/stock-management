import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class WarehouseManagementTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: StockModelContainer.schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: StockModelContainer.schema, configurations: [configuration]))
    }

    func testWarehouseIsolationAndCascadeDeletion() throws {
        let ctx = try makeContext()
        let store = InventoryStore(context: ctx)
        let warehouseManager = WarehouseStore.shared

        // 1. 添加并切换至两个仓库
        warehouseManager.addWarehouse("主仓库")
        warehouseManager.addWarehouse("冷链库")
        XCTAssertTrue(warehouseManager.warehouses.contains("主仓库"))
        XCTAssertTrue(warehouseManager.warehouses.contains("冷链库"))

        // 2. 创建物料与批次
        let sku = RawMaterialSKU(skuCode: "SKU-BEEF", skuName: "精品肥牛卷", categoryName: "食品生鲜", baseUnit: "盒")
        ctx.insert(sku)
        let unit = PackagingUnit(unitName: "盒", conversionRatio: 1.0, sku: sku)
        ctx.insert(unit)
        let batchA = StockBatch(batchNo: "B-A01", inboundPrice: 35.0, sku: sku)
        let batchB = StockBatch(batchNo: "B-B01", inboundPrice: 38.0, sku: sku)
        ctx.insert(batchA)
        ctx.insert(batchB)
        try ctx.save()

        // 3. 分别在 主仓库 入库 100 盒，在 冷链库 入库 50 盒
        let lineA = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchA, operatingQty: 100, conversionRatio: 1.0, mode: .manual)
        let orderA = try store.processOrder(type: "INBOUND", lines: [lineA], location: "主仓库")
        XCTAssertEqual(orderA.locationName, "主仓库")

        let lineB = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchB, operatingQty: 50, conversionRatio: 1.0, mode: .manual)
        let orderB = try store.processOrder(type: "INBOUND", lines: [lineB], location: "冷链库")
        XCTAssertEqual(orderB.locationName, "冷链库")

        // 4. 验证多仓库数据与估值独立隔离
        let valA = store.calculateTotalValuation(location: "主仓库")
        XCTAssertEqual(valA.totalValue, 3500.0, accuracy: 0.001, "主仓库货值 100 * 35 = 3500")
        XCTAssertEqual(valA.totalItemCount, 100.0)

        let valB = store.calculateTotalValuation(location: "冷链库")
        XCTAssertEqual(valB.totalValue, 1900.0, accuracy: 0.001, "冷链库货值 50 * 38 = 1900")
        XCTAssertEqual(valB.totalItemCount, 50.0)

        // 5. 执行级联删除「主仓库」
        try warehouseManager.deleteWarehouse("主仓库", context: ctx)

        // 验证主仓库列表已被移除
        XCTAssertFalse(warehouseManager.warehouses.contains("主仓库"))

        // 验证主仓库库存已被清空
        let valAAfter = store.calculateTotalValuation(location: "主仓库")
        XCTAssertEqual(valAAfter.totalValue, 0.0)
        XCTAssertEqual(valAAfter.totalItemCount, 0.0)

        // 验证主仓库的单据已被级联删除
        let orderDescriptor = FetchDescriptor<StockOrderHeader>()
        let allOrders = try ctx.fetch(orderDescriptor)
        XCTAssertFalse(allOrders.contains(where: { $0.locationName == "主仓库" }))
        XCTAssertTrue(allOrders.contains(where: { $0.locationName == "冷链库" }), "冷链库单据应完好保留")

        // 验证冷链库的库存和估值完好无损
        let valBAfter = store.calculateTotalValuation(location: "冷链库")
        XCTAssertEqual(valBAfter.totalValue, 1900.0, accuracy: 0.001)
        XCTAssertEqual(valBAfter.totalItemCount, 50.0)
    }
}
