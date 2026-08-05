import XCTest
import UIKit
@testable import StockInventoryApp

final class LocalFeatureEngineTests: XCTestCase {
    func testVectorDataRoundTripPreservesFloat32Values() throws {
        let vector: [Float] = [0.25, -1.5, 8.75, 0]

        let decoded = try LocalFeatureEngine.decodeVector(LocalFeatureEngine.toData(vector))

        XCTAssertEqual(decoded, vector)
    }

    func testDecodeVectorRejectsMisalignedByteCount() {
        XCTAssertThrowsError(try LocalFeatureEngine.decodeVector(Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? LocalFeatureEngine.VectorError, .invalidByteCount(3))
        }
    }

    func testNormalizeRejectsNonFiniteAndZeroVectors() {
        XCTAssertThrowsError(try LocalFeatureEngine.normalized([1, .nan])) { error in
            XCTAssertEqual(error as? LocalFeatureEngine.VectorError, .nonFiniteValue)
        }
        XCTAssertThrowsError(try LocalFeatureEngine.normalized([0, 0])) { error in
            XCTAssertEqual(error as? LocalFeatureEngine.VectorError, .zeroNorm)
        }
    }

    func testCosineSimilarityRejectsDimensionMismatchAndInvalidValues() {
        XCTAssertEqual(LocalFeatureEngine.cosineSimilarity([1, 0], [1]), 0)
        XCTAssertEqual(LocalFeatureEngine.cosineSimilarity([1, .infinity], [1, 0]), 0)
    }

    func testCosineSimilarityRanksEquivalentDirectionAsOne() throws {
        let lhs = try LocalFeatureEngine.normalized([3, 4])
        let rhs = try LocalFeatureEngine.normalized([6, 8])

        XCTAssertEqual(LocalFeatureEngine.cosineSimilarity(lhs, rhs), 1, accuracy: 0.000_001)
    }
}

final class CapturedImageProcessorTests: XCTestCase {
    func testProcessingDownsamplesLongEdgeAndProducesJPEG() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2_400, height: 1_200)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_200))
        }
        let input = try XCTUnwrap(source.pngData())

        let output = try await CapturedImageProcessor().process(input)

        XCTAssertEqual(max(output.pixelWidth, output.pixelHeight), 1_024)
        XCTAssertEqual(output.pixelWidth, 1_024)
        XCTAssertEqual(output.pixelHeight, 512)
        XCTAssertEqual(Array(output.jpegData.prefix(2)), [0xFF, 0xD8])
    }

    func testProcessingRejectsInvalidImageData() async {
        do {
            _ = try await CapturedImageProcessor().process(Data("not an image".utf8))
            XCTFail("Expected invalid image data to throw")
        } catch {
            XCTAssertEqual(error as? CapturedImageProcessor.ProcessingError, .invalidImageData)
        }
    }
}
