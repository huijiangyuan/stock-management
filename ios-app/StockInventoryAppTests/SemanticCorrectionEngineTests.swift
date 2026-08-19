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
        // 食品生鲜
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "德克士脆皮炸鸡"), "食品生鲜")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "香辣鸡腿堡"), "食品生鲜")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "精品肥牛卷"), "食品生鲜")

        // 酒水饮料
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "330ml可口可乐听装"), "酒水饮料")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "特级黑咖啡饮料"), "酒水饮料")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "农夫山泉饮用水"), "酒水饮料")

        // 办公耗材
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "得力A4 70g复印纸"), "办公耗材")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "晨光黑色签字笔"), "办公耗材")

        // 五金与紧固件
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "M8不锈钢螺栓"), "五金配件")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "精密微型滚珠轴承"), "五金配件")

        // 金属材料
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "高纯度紫铜管"), "金属材料")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "304冷轧钢板"), "金属材料")

        // 包装耗材
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "五层瓦楞纸箱 50*40*30"), "包装耗材")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "加厚透明封箱胶带"), "包装耗材")

        // 化工与辅料
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "特级润滑硅脂"), "化工辅料")
        XCTAssertEqual(SemanticCorrectionEngine.inferCategory(from: "502强力快干胶水"), "化工辅料")
    }

    func testCategoryInferencePrioritizesExistingCategories() {
        let existing = ["西式快餐", "金属管材管件", "紧固件库"]
        
        // 匹配已有的“西式快餐”
        let cat = SemanticCorrectionEngine.inferCategory(from: "德克士炸鸡", existingCategories: existing)
        XCTAssertEqual(cat, "西式快餐")
    }

    func testBaseUnitInference() {
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "高纯度铜管"), "根")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "德克士汉堡套餐"), "份")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "冷轧钢板"), "张")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "工业润滑油"), "桶")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "矿泉水饮料"), "瓶")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "330ml听装可乐"), "听")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "八宝粥罐装"), "罐")
        XCTAssertEqual(SemanticCorrectionEngine.inferBaseUnit(from: "中性水笔"), "根")
    }

    func testShelfLifeStrictInferenceDoesNotGuessWhenMissing() {
        // 有明确保质期关键词：正常解析
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "常温保质期: 12个月"), 360)
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "保质期 180天"), 180)
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "有效期: 2年"), 730)
        XCTAssertEqual(SemanticCorrectionEngine.inferShelfLifeDays(from: "EXP: 90 days"), 90)

        // 关键用例：没有保质期文字时，严禁乱填！绝对不能把日期、数量、价格误当保质期
        XCTAssertNil(SemanticCorrectionEngine.inferShelfLifeDays(from: "生产日期: 2026年08月19日"))
        XCTAssertNil(SemanticCorrectionEngine.inferShelfLifeDays(from: "包装数量: 100个 入库价格 25元"))
        XCTAssertNil(SemanticCorrectionEngine.inferShelfLifeDays(from: "304不锈钢无缝钢管 6米/根"))
        XCTAssertNil(SemanticCorrectionEngine.inferShelfLifeDays(from: "2026/08/19 14:30:00 合格品"))
    }

    func testSupplierInference() {
        let text1 = "生产商: 统一企业(中国)投资有限公司 地址: 上海市"
        XCTAssertEqual(SemanticCorrectionEngine.inferSupplier(from: text1), "统一企业(中国)投资有限公司")

        let text2 = "供应商: 雀巢中国有限公司 批次: 20260819"
        XCTAssertEqual(SemanticCorrectionEngine.inferSupplier(from: text2), "雀巢中国有限公司")

        let text3 = "普通商品无厂家信息"
        XCTAssertNil(SemanticCorrectionEngine.inferSupplier(from: text3))
    }

    func testPackagingSpecificationInference() {
        let spec1 = SemanticCorrectionEngine.inferPackagingSpecification(from: "可口可乐 24瓶/箱 330ml")
        XCTAssertEqual(spec1?.unitName, "箱")
        XCTAssertEqual(spec1?.conversionRatio, 24.0)

        let spec2 = SemanticCorrectionEngine.inferPackagingSpecification(from: "精品特级白茶 12盒装 礼盒")
        XCTAssertEqual(spec2?.unitName, "箱")
        XCTAssertEqual(spec2?.conversionRatio, 12.0)

        let spec3 = SemanticCorrectionEngine.inferPackagingSpecification(from: "普通散装螺栓")
        XCTAssertNil(spec3)
    }
}
