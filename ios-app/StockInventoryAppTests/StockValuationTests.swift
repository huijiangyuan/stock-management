import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class StockValuationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: StockModelContainer.schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: StockModelContainer.schema, configurations: [configuration]))
    }

    func testValuationCalculationWithBatchesAndPrices() throws {
        let ctx = try makeContext()
        let store = InventoryStore(context: ctx)

        // SKU 1: 可口可乐, 2 个批次 (批次1: 100瓶 @ 2.5元, 批次2: 50瓶 @ 3.0元) -> 货值: 250 + 150 = 400元
        let sku1 = RawMaterialSKU(skuCode: "SKU-COLA", skuName: "可口可乐", categoryName: "酒水饮料", baseUnit: "瓶")
        ctx.insert(sku1)

        let batch1 = StockBatch(batchNo: "B20260819-01", inboundPrice: 2.5, sku: sku1)
        let batch2 = StockBatch(batchNo: "B20260819-02", inboundPrice: 3.0, sku: sku1)
        ctx.insert(batch1)
        ctx.insert(batch2)

        let inv1 = StockInventory(qtyBaseUnit: 100, sku: sku1, batch: batch1)
        let inv2 = StockInventory(qtyBaseUnit: 50, sku: sku1, batch: batch2)
        ctx.insert(inv1)
        ctx.insert(inv2)

        // SKU 2: M8螺栓, 1 个批次 (2000个 @ 0.5元) -> 货值: 1000元
        let sku2 = RawMaterialSKU(skuCode: "SKU-BOLT", skuName: "M8不锈钢螺栓", categoryName: "五金配件", baseUnit: "个")
        ctx.insert(sku2)

        let batch3 = StockBatch(batchNo: "B20260819-03", inboundPrice: 0.5, sku: sku2)
        ctx.insert(batch3)

        let inv3 = StockInventory(qtyBaseUnit: 2000, sku: sku2, batch: batch3)
        ctx.insert(inv3)

        // SKU 3: A4纸, 无单价批次 -> 货值: 0元
        let sku3 = RawMaterialSKU(skuCode: "SKU-PAPER", skuName: "A4复印纸", categoryName: "办公耗材", baseUnit: "包")
        ctx.insert(sku3)

        let batch4 = StockBatch(batchNo: "B20260819-04", inboundPrice: nil, sku: sku3)
        ctx.insert(batch4)

        let inv4 = StockInventory(qtyBaseUnit: 20, sku: sku3, batch: batch4)
        ctx.insert(inv4)

        try ctx.save()

        let summary = store.calculateTotalValuation()

        // 总货值 = 400 + 1000 + 0 = 1400 元
        XCTAssertEqual(summary.totalValue, 1400.0, accuracy: 0.001)
        XCTAssertEqual(summary.valuedSKUCount, 2, "2 种物料已定价")
        XCTAssertEqual(summary.totalSKUCount, 3, "在库共 3 种物料")
        XCTAssertEqual(summary.totalItemCount, 2170.0, accuracy: 0.001, "总在库数量 100+50+2000+20=2170")

        // 高价值排行：SKU2(1000元) > SKU1(400元)
        XCTAssertEqual(summary.topValuedItems.count, 2)
        XCTAssertEqual(summary.topValuedItems[0].sku.skuCode, "SKU-BOLT")
        XCTAssertEqual(summary.topValuedItems[0].value, 1000.0, accuracy: 0.001)
        XCTAssertEqual(summary.topValuedItems[1].sku.skuCode, "SKU-COLA")
        XCTAssertEqual(summary.topValuedItems[1].value, 400.0, accuracy: 0.001)
    }

    func testValuationFallbackToPreviousBatchPrice() throws {
        let ctx = try makeContext()
        let store = InventoryStore(context: ctx)

        let sku = RawMaterialSKU(skuCode: "SKU-OIL", skuName: "特级润滑硅脂", categoryName: "化工辅料", baseUnit: "桶")
        ctx.insert(sku)

        // 历史批次 1 有单价 50 元，但库存为 0
        let batch1 = StockBatch(batchNo: "B20260101-01", inboundPrice: 50.0, sku: sku)
        ctx.insert(batch1)
        let inv1 = StockInventory(qtyBaseUnit: 0, sku: sku, batch: batch1)
        ctx.insert(inv1)

        // 新批次 2 没填单价，但库存有 10 桶
        let batch2 = StockBatch(batchNo: "B20260819-02", inboundPrice: nil, sku: sku)
        ctx.insert(batch2)
        let inv2 = StockInventory(qtyBaseUnit: 10, sku: sku, batch: batch2)
        ctx.insert(inv2)

        try ctx.save()

        let summary = store.calculateTotalValuation()

        // 应回退使用历史批次的 50 元单价 -> 10 * 50 = 500 元
        XCTAssertEqual(summary.totalValue, 500.0, accuracy: 0.001)
        XCTAssertEqual(summary.valuedSKUCount, 1)
    }
}
