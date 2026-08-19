import XCTest
@testable import StockInventoryApp

final class ExportImportTests: XCTestCase {
    func testLegacyFeatureSampleDTOStillDecodesWithoutVectorMetadata() throws {
        let json = Data(#"""
        {
          "sampleId": "legacy-sample",
          "angleTag": "FRONT",
          "ocrTextContent": "旧商品",
          "sampleImagePath": null,
          "visionEmbeddingBase64": null,
          "textEmbeddingBase64": null
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(FeatureSampleDTO.self, from: json)

        XCTAssertEqual(decoded.sampleId, "legacy-sample")
        XCTAssertNil(decoded.unitId)
        XCTAssertNil(decoded.visionModelVersion)
        XCTAssertNil(decoded.visionVectorDimension)
    }

    func testFeatureSampleDTORoundTripPreservesVectorCompatibilityMetadata() throws {
        let dto = FeatureSampleDTO(
            sampleId: "sample-1",
            angleTag: "FRONT",
            unitId: "unit-1",
            ocrTextContent: "商品",
            sampleImagePath: nil,
            visionEmbeddingBase64: "AAAAAA==",
            visionModelVersion: "test-v1",
            visionVectorDimension: 512,
            textEmbeddingBase64: nil
        )

        let decoded = try JSONDecoder().decode(
            FeatureSampleDTO.self,
            from: JSONEncoder().encode(dto)
        )

        XCTAssertEqual(decoded.unitId, "unit-1")
        XCTAssertEqual(decoded.visionModelVersion, "test-v1")
        XCTAssertEqual(decoded.visionVectorDimension, 512)
    }

    func testExportOrdersCSVProducesValidUTF8BOMFile() throws {
        let sku = RawMaterialSKU(skuCode: "SKU-001", skuName: "测试物料", categoryName: "默认品类", baseUnit: "瓶")
        let unit = PackagingUnit(unitName: "箱", unitType: "LARGE", conversionRatio: 24.0, sku: sku)
        let batch = StockBatch(batchNo: "BAT-20260819-01", supplierName: "优质供应商A", inboundPrice: 15.5, sku: sku)
        let order = StockOrderHeader(orderNo: "ORD-20260819-01", orderType: "INBOUND")
        let item = StockOrderItem(operatingQty: 2, conversionRatio: 24.0, totalBaseQty: 48.0, header: order, sku: sku, unit: unit, batch: batch)
        order.items.append(item)

        let url = try ExportImport.exportOrdersCSV(orders: [order], timeRangeTitle: "本月")
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)

        XCTAssertNotNil(text)
        XCTAssertTrue(text!.starts(with: "\u{FEFF}"))
        XCTAssertTrue(text!.contains("单据编号"))
        XCTAssertTrue(text!.contains("供应商"))
        XCTAssertTrue(text!.contains("入库单价(元)"))
        XCTAssertTrue(text!.contains("优质供应商A"))
        XCTAssertTrue(text!.contains("15.5"))
        XCTAssertTrue(text!.contains("31")) // 15.5 * 2
        XCTAssertTrue(text!.contains("ORD-20260819-01"))
        XCTAssertTrue(text!.contains("入库单"))
        XCTAssertTrue(text!.contains("测试物料"))
        XCTAssertTrue(text!.contains("48"))
    }

    func testDateFormattersProducePureChineseNumericDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = AppFormatters.dateTime.timeZone
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = 14
        components.minute = 30
        guard let testDate = calendar.date(from: components) else {
            XCTFail("无法构造测试日期")
            return
        }

        let dateStr = AppFormatters.date.string(from: testDate)
        XCTAssertEqual(dateStr, "2026-08-19")
        // 确保不包含任何英文月份简写
        let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for m in englishMonths {
            XCTAssertFalse(dateStr.contains(m), "日期不应包含英文月份 \(m)")
        }

        let chineseDateStr = AppFormatters.chineseDate.string(from: testDate)
        XCTAssertEqual(chineseDateStr, "2026年08月19日")

        let dateTimeStr = AppFormatters.dateTime.string(from: testDate)
        XCTAssertEqual(dateTimeStr, "2026-08-19 14:30")

        XCTAssertEqual(AppFormatters.formatDate(nil), "—")
        XCTAssertEqual(AppFormatters.formatDateTime(nil), "—")
        XCTAssertEqual(AppFormatters.formatChineseDate(nil), "—")
    }
}
