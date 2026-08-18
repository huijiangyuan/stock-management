import XCTest
@testable import StockInventoryApp

final class VisionOCREngineTests: XCTestCase {

    func testIsTextMatching() {
        let ocrText = "特级黑咖啡 净含量500g 生产企业: 优质食品厂"
        XCTAssertTrue(VisionOCREngine.isTextMatching(ocrFullText: ocrText, candidateSKUName: "特级黑咖啡"))
        XCTAssertTrue(VisionOCREngine.isTextMatching(ocrFullText: ocrText, candidateSKUName: "黑咖啡"))
        XCTAssertFalse(VisionOCREngine.isTextMatching(ocrFullText: ocrText, candidateSKUName: "高纯度铜管"))
    }

    func testIsTextConflictingWhenSameBoxHasDifferentNames() {
        // 场景：图片上的文字是“高纯度铜管”，候选商品是“特级黑咖啡”
        let ocrText = "工业精密部件 高纯度铜管 规格 20mm"
        let terms = ["高纯度铜管", "工业精密部件"]
        
        // 候选是咖啡 -> 明确冲突！
        XCTAssertTrue(VisionOCREngine.isTextConflicting(
            ocrFullText: ocrText,
            ocrTerms: terms,
            candidateSKUName: "特级黑咖啡"
        ))

        // 候选是铜管 -> 不冲突（匹配）
        XCTAssertFalse(VisionOCREngine.isTextConflicting(
            ocrFullText: ocrText,
            ocrTerms: terms,
            candidateSKUName: "高纯度铜管"
        ))
    }

    func testNoTextDoesNotConflict() {
        // 纯无字物品不属于文本冲突
        XCTAssertFalse(VisionOCREngine.isTextConflicting(
            ocrFullText: "",
            ocrTerms: [],
            candidateSKUName: "高纯度铜管"
        ))
    }
}
