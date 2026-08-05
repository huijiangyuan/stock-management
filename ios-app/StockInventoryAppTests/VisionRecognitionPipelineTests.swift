import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class VisionRecognitionPipelineTests: XCTestCase {
    func testHighConfidenceVectorMatchSkipsFallback() async throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "SKU-1", skuName: "测试商品", categoryName: "测试")
        let sample = FeatureSample(sku: sku)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.91)]),
            fallback: { _ in
                fallbackCalled = true
                return (RecognitionResult(confidence: 0, mode: .vision, needsLearning: true), .miniCPM)
            }
        )

        let outcome = try await pipeline.recognize(rawImageData: Data([0x01]))

        XCTAssertFalse(fallbackCalled)
        XCTAssertEqual(outcome.source, .vector)
        XCTAssertEqual(outcome.result.sku?.skuCode, "SKU-1")
        XCTAssertEqual(outcome.matches.count, 1)
    }

    func testLowConfidenceVectorMatchInvokesFallback() async throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "SKU-LOW", skuName: "低分商品", categoryName: "测试")
        let sample = FeatureSample(sku: sku)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.42)]),
            fallback: { _ in
                fallbackCalled = true
                return (
                    RecognitionResult(confidence: 0.8, mode: .vision, needsLearning: false, recognizedName: "VLM 商品"),
                    .miniCPM
                )
            }
        )

        let outcome = try await pipeline.recognize(rawImageData: Data([0x01]))

        XCTAssertTrue(fallbackCalled)
        XCTAssertEqual(outcome.source, .miniCPM)
        XCTAssertEqual(outcome.result.recognizedName, "VLM 商品")
        XCTAssertEqual(outcome.matches.first?.similarity, 0.42)
    }

    func testMediumConfidenceVectorMatchReturnsCandidatesWithoutFallback() async throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "SKU-MID", skuName: "中分商品", categoryName: "测试")
        let sample = FeatureSample(sku: sku)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.72)]),
            fallback: { _ in
                fallbackCalled = true
                return (RecognitionResult(confidence: 0, mode: .vision, needsLearning: true), .miniCPM)
            }
        )

        let outcome = try await pipeline.recognize(rawImageData: Data([0x01]))

        XCTAssertFalse(fallbackCalled)
        XCTAssertEqual(outcome.source, .vector)
        XCTAssertEqual(outcome.result.sku?.skuCode, "SKU-MID")
        XCTAssertTrue(outcome.result.needsLearning)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: StockModelContainer.schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: StockModelContainer.schema, configurations: [configuration]))
    }
}

private actor FakeImageProcessor: CapturedImageProcessing {
    func process(_ imageData: Data) throws -> ProcessedCapturedImage {
        ProcessedCapturedImage(jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), pixelWidth: 10, pixelHeight: 10)
    }
}

private actor FakeEmbeddingEngine: ImageEmbeddingProviding {
    func embed(imageData: Data) async throws -> ImageEmbedding {
        ImageEmbedding(values: [1, 0], modelVersion: "test-v1")
    }
}

@MainActor
private final class FakeFeatureSearch: FeatureSearching {
    let matches: [FeatureMatch]

    init(matches: [FeatureMatch]) {
        self.matches = matches
    }

    func topMatches(queryVector: [Float], modelVersion: String, topK: Int) throws -> [FeatureMatch] {
        Array(matches.prefix(topK))
    }
}
