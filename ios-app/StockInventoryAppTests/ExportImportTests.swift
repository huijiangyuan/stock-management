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
}
