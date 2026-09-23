//
//  OutboundAndOutOfStockTests.swift
//  StockInventoryAppTests · 出库扣减与缺货判定业务测试
//

import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class OutboundAndOutOfStockTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: StockModelContainer.schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: StockModelContainer.schema, configurations: [configuration]))
    }

    /// 验证出库后库存真实扣减，以及未指定批次时的底层 FIFO 自动兜底扣减
    func testOutboundInventoryDeductionWithAndWithoutExplicitBatch() throws {
        let ctx = try makeContext()
        let store = InventoryStore(context: ctx)

        // 1. 创建商品与单位
        let sku = RawMaterialSKU(skuCode: "SKU-BEARING", skuName: "精密轴承", categoryName: "五金配件", baseUnit: "个")
        ctx.insert(sku)
        let unit = PackagingUnit(unitName: "个", unitType: "BASE", conversionRatio: 1.0, sku: sku)
        ctx.insert(unit)

        // 2. 入库两个批次：批次 1 (50个，早到期)，批次 2 (100个，晚到期)
        let cal = Calendar.current
        let exp1 = cal.date(byAdding: .day, value: 10, to: Date())
        let exp2 = cal.date(byAdding: .day, value: 30, to: Date())

        let batch1 = StockBatch(batchNo: "B-2026-01", expirationDate: exp1, sku: sku)
        let batch2 = StockBatch(batchNo: "B-2026-02", expirationDate: exp2, sku: sku)
        ctx.insert(batch1)
        ctx.insert(batch2)
        try ctx.save()

        let inLine1 = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batch1, operatingQty: 50, conversionRatio: 1.0, mode: .manual)
        try store.processOrder(type: "INBOUND", lines: [inLine1], location: "主仓库")

        let inLine2 = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batch2, operatingQty: 100, conversionRatio: 1.0, mode: .manual)
        try store.processOrder(type: "INBOUND", lines: [inLine2], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 150)

        // 3. 显式指定批次 1 出库 20 个
        let outLine1 = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batch1, operatingQty: 20, conversionRatio: 1.0, mode: .manual)
        try store.processOrder(type: "OUTBOUND", lines: [outLine1], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 130, "总库存应扣减为 130")
        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku, batch: batch1), 30, "批次1应扣减为 30")

        // 4. 未显式指定批次（batch 为 nil）出库 40 个：应自动按 FIFO 扣除批次 1 的 30 个，再自动顺延扣除批次 2 的 10 个
        let outLine2 = InventoryStore.OrderLine(sku: sku, unit: unit, batch: nil, operatingQty: 40, conversionRatio: 1.0, mode: .manual)
        try store.processOrder(type: "OUTBOUND", lines: [outLine2], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 90, "总库存应扣减为 90")
        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku, batch: batch1), 0, "最早批次 1 应被完全扣完为 0")
        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku, batch: batch2), 90, "批次 2 顺延扣减 10 个，剩余 90")
    }

    /// 验证有货时不误报缺货，以及全部出库完后准确报缺货
    func testOutOfStockAccurateLogic() throws {
        let ctx = try makeContext()
        let store = InventoryStore(context: ctx)

        let sku = RawMaterialSKU(skuCode: "SKU-TEA", skuName: "高山红茶", categoryName: "茶叶", baseUnit: "罐")
        ctx.insert(sku)
        let unit = PackagingUnit(unitName: "罐", unitType: "BASE", conversionRatio: 1.0, sku: sku)
        ctx.insert(unit)

        // 1. 刚刚创建但未入库的 SKU，库存为 0，应准确判定为缺货
        let initialOutOfStock = store.outOfStock(location: "主仓库")
        XCTAssertTrue(initialOutOfStock.contains(where: { $0.skuCode == "SKU-TEA" }), "无库存商品应提示缺货")

        // 2. 入库两个批次：批次 A 10罐，批次 B 20罐
        let batchA = StockBatch(batchNo: "BATCH-A", sku: sku)
        let batchB = StockBatch(batchNo: "BATCH-B", sku: sku)
        ctx.insert(batchA)
        ctx.insert(batchB)
        try ctx.save()

        try store.processOrder(type: "INBOUND", lines: [
            InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchA, operatingQty: 10, conversionRatio: 1.0, mode: .manual),
            InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchB, operatingQty: 20, conversionRatio: 1.0, mode: .manual)
        ], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 30)

        // 此时绝不可判定为缺货
        XCTAssertFalse(store.outOfStock(location: "主仓库").contains(where: { $0.skuCode == "SKU-TEA" }))

        // 3. 将批次 A 全部出库（批次 A 变为 0，但批次 B 还有 20 罐）
        try store.processOrder(type: "OUTBOUND", lines: [
            InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchA, operatingQty: 10, conversionRatio: 1.0, mode: .manual)
        ], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 20)
        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku, batch: batchA), 0)

        // 关键断言：虽然存在数量为 0 的批次记录，但由于商品整体仍有 20 罐，绝对不能报缺货！
        XCTAssertFalse(store.outOfStock(location: "主仓库").contains(where: { $0.skuCode == "SKU-TEA" }), "某批次售罄但其它批次有货时，绝不应误报缺货")

        // 4. 将批次 B 也全部出库
        try store.processOrder(type: "OUTBOUND", lines: [
            InventoryStore.OrderLine(sku: sku, unit: unit, batch: batchB, operatingQty: 20, conversionRatio: 1.0, mode: .manual)
        ], location: "主仓库")

        XCTAssertEqual(store.totalQty(location: "主仓库", sku: sku), 0)

        // 此时全部售罄，必须准确判定为缺货
        XCTAssertTrue(store.outOfStock(location: "主仓库").contains(where: { $0.skuCode == "SKU-TEA" }), "总库存真正归零时，准确判定为缺货")
    }
}
