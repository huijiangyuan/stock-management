import XCTest
@testable import StockInventoryApp

final class OnDeviceJSONParserTests: XCTestCase {

    func testParseStandardJSON() {
        let text = "{\"名称\":\"纯正橡胶圈\",\"规格单位\":\"个\",\"品类\":\"密封五金\",\"保质期天数\":365,\"条码\":\"6901234567890\",\"生产日期\":\"2026-08-01\",\"保质期\":\"2027-08-01\",\"置信度\":0.92}"
        let result = OnDeviceVisionEngine.parseResult(text, imageData: Data())

        XCTAssertEqual(result.recognizedName, "纯正橡胶圈")
        XCTAssertEqual(result.recognizedUnit, "个")
        XCTAssertEqual(result.recognizedCategory, "密封五金")
        XCTAssertEqual(result.recognizedShelfLifeDays, 365)
        XCTAssertEqual(result.recognizedBarcode, "6901234567890")
        XCTAssertEqual(result.displayUnitName, "个")
        XCTAssertEqual(result.displayCategoryName, "密封五金")
        XCTAssertEqual(result.displayShelfLifeDays, 365)
        XCTAssertEqual(result.confidence, 0.92, accuracy: 0.001)
        XCTAssertFalse(result.needsLearning)
        XCTAssertNotNil(result.productionDate)
        XCTAssertNotNil(result.expirationDate)
    }

    func testParseMarkdownWrappedJSON() {
        let text = """
        ```json
        {
          "名称": "高纯度铜管",
          "规格单位": "根",
          "品类": "管材管件",
          "保质期天数": 730,
          "生产日期": "2026-05-20",
          "保质期": "2028-05-20",
          "置信度": 0.88
        }
        ```
        """
        let result = OnDeviceVisionEngine.parseResult(text, imageData: Data())

        XCTAssertEqual(result.recognizedName, "高纯度铜管")
        XCTAssertEqual(result.displayUnitName, "根")
        XCTAssertEqual(result.displayCategoryName, "管材管件")
        XCTAssertEqual(result.displayShelfLifeDays, 730)
        XCTAssertEqual(result.confidence, 0.88, accuracy: 0.001)
        XCTAssertFalse(result.needsLearning)
    }

    func testParseTruncatedRepairedJSON() {
        // 因达到 token 上限被截断未闭合的 JSON
        let text = "{\"名称\":\"精密微型滚珠轴承\",\"规格单位\":\"盒\",\"品类\":\"传动件\",\"保质期天数\":1095,\"生产日期\":\"2026-08-10\",\"保质期\":\"2029-08-10"
        let result = OnDeviceVisionEngine.parseResult(text, imageData: Data())

        XCTAssertEqual(result.recognizedName, "精密微型滚珠轴承")
        XCTAssertEqual(result.displayUnitName, "盒")
        XCTAssertEqual(result.displayCategoryName, "传动件")
        XCTAssertEqual(result.displayShelfLifeDays, 1095)
        XCTAssertNotNil(result.productionDate)
    }

    func testParseMonthFormatShelfLife() {
        let text = "{\"名称\":\"特级黑咖啡\",\"规格单位\":\"罐\",\"品类\":\"饮品\",\"保质期天数\":\"18个月\",\"置信度\":0.90}"
        let result = OnDeviceVisionEngine.parseResult(text, imageData: Data())

        XCTAssertEqual(result.recognizedName, "特级黑咖啡")
        XCTAssertEqual(result.displayUnitName, "罐")
        XCTAssertEqual(result.displayShelfLifeDays, 540) // 18 * 30
    }

    func testParseRegexFallback() {
        let text = "识别结果如下：品名: \"特级润滑硅脂\"，包装单位: \"桶\"，分类: \"化工辅料\"，置信度: 0.85，请核对。"
        let result = OnDeviceVisionEngine.parseResult(text, imageData: Data())

        XCTAssertEqual(result.recognizedName, "特级润滑硅脂")
        XCTAssertEqual(result.displayUnitName, "桶")
        XCTAssertEqual(result.displayCategoryName, "化工辅料")
        XCTAssertEqual(result.confidence, 0.85, accuracy: 0.001)
    }

    func testCompleteJSONEarlyStopPredicate() {
        // 未闭合的 JSON 不应触发早停
        let incomplete = "{\"名称\":\"不锈钢螺栓\",\"规格单位\":\""
        XCTAssertFalse(OnDeviceVisionEngine.isCompleteJSON(incomplete))

        // 包含完整合法闭合 JSON 应触发早停
        let complete = "{\"名称\":\"不锈钢螺栓\",\"规格单位\":\"包\",\"置信度\":0.95}"
        XCTAssertTrue(OnDeviceVisionEngine.isCompleteJSON(complete))

        // 带有前后缀文本的完整 JSON 也能判定
        let wrapped = "好的，结果是：{\"名称\":\"滤芯\",\"规格单位\":\"个\"}，请查收。"
        XCTAssertTrue(OnDeviceVisionEngine.isCompleteJSON(wrapped))
    }
}
