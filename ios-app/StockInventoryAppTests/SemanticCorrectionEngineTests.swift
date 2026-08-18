import XCTest
@testable import StockInventoryApp

final class SemanticCorrectionEngineTests: XCTestCase {

    func testDicosHomoglyphCorrection() {
        // 测试“德克上”精准纠错为“德克士”
        let raw = "德克上"
        let corrected = SemanticCorrectionEngine.correctText(raw)
        XCTAssertEqual(corrected, "德克士")

        // 包含前后缀
        let raw2 = "德克上脆皮炸鸡"
        let corrected2 = SemanticCorrectionEngine.correctText(raw2)
        XCTAssertEqual(corrected2, "德克士脆皮炸鸡")
    }

    func testGeneralBrandAndEntityCorrection() {
        // 可口町乐 -> 可口可乐
        XCTAssertEqual(SemanticCorrectionEngine.correctText("可口町乐"), "可口可乐")
        // 不锈铜 -> 不锈钢
        XCTAssertEqual(SemanticCorrectionEngine.correctText("不锈铜内六角螺栓"), "不锈钢内六角螺栓")
    }

    func testCategoryInference() {
        // 餐饮食品
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "德克士"), "食品餐饮")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "香辣鸡腿堡"), "食品餐饮")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "特级黑咖啡"), "食品餐饮")

        // 五金与紧固件
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "M8不锈钢螺栓"), "五金配件")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "精密微型滚珠轴承"), "五金配件")

        // 金属材料
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "高纯度紫铜管"), "金属材料")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "304冷轧钢板"), "金属材料")

        // 化工与辅料
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "特级润滑硅脂"), "化工辅料")
    }

    func testCategoryInferencePrioritizesExistingCategories() {
        let existing = ["西式快餐", "金属管材管件", "紧固件库"]
        
        // 匹配已有的“西式快餐”
        let cat = SemanticCorrectionEngine.inferCategory(from: "德克士炸鸡", existingCategories: existing)
        XCTAssertEqual(cat, "西式快餐")
    }

    func testBaseUnitAndShelfLifeInference() {
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "高纯度铜管"), "根")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "德克士汉堡套餐"), "份")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "冷轧钢板"), "张")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "工业润滑油"), "桶")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "矿泉水饮料"), "瓶")

        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "常温保质期12个月"), 360)
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "保质期 180天"), 180)
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "保质期2年"), 730)
    }
}
