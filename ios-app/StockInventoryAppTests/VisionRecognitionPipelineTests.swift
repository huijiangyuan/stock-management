import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class VisionRecognitionPipelineTests: XCTestCase {

    func testHighConfidenceNoTextVectorMatchSkipsFallback() async throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "SKU-1", skuName: "纯金属铜块", categoryName: "金属")
        let sample = FeatureSample(sku: sku)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            ocrEngine: FakeOCREngine(result: VisionOCREngine.OCRResult(lines: [], fullText: "", topCandidateTerms: [])),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.93)]),
            vectorAutoSelectionThreshold: 0.90,
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

    func testOCRTextMatchWithVectorDirectSuccess() async throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "SKU-COFFEE", skuName: "特级黑咖啡", categoryName: "饮品")
        let sample = FeatureSample(sku: sku)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            ocrEngine: FakeOCREngine(result: VisionOCREngine.OCRResult(
                lines: ["精选原豆", "特级黑咖啡", "500g"],
                fullText: "精选原豆 特级黑咖啡 500g",
                topCandidateTerms: ["特级黑咖啡", "精选原豆"]
            )),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.78)]),
            fallback: { _ in
                fallbackCalled = true
                return (RecognitionResult(confidence: 0, mode: .vision, needsLearning: true), .miniCPM)
            }
        )

        let outcome = try await pipeline.recognize(rawImageData: Data([0x01]))

        XCTAssertFalse(fallbackCalled, "OCR 文字与向量均匹配时应直接多模态命中，无需等待 VLM")
        XCTAssertEqual(outcome.source, .vector)
        XCTAssertEqual(outcome.result.sku?.skuName, "特级黑咖啡")
    }

    func testSimilarBoxWithConflictingTextInvokesVLM() async throws {
        // 场景：两件物品都是黄色瓦楞纸箱（向量相似度高达 0.86），但图片上写着“高纯度铜管”，库里之前存的纸箱是“特级黑咖啡”
        let context = try makeContext()
        let oldSKU = RawMaterialSKU(skuCode: "SKU-COFFEE", skuName: "特级黑咖啡", categoryName: "饮品")
        let sample = FeatureSample(sku: oldSKU)
        var fallbackCalled = false
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            ocrEngine: FakeOCREngine(result: VisionOCREngine.OCRResult(
                lines: ["工业材料", "高纯度铜管", "规格 20mm"],
                fullText: "工业材料 高纯度铜管 规格 20mm",
                topCandidateTerms: ["高纯度铜管", "工业材料"]
            )),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.86)]),
            fallback: { _ in
                fallbackCalled = true
                return (
                    RecognitionResult(
                        confidence: 0.95,
                        mode: .vision,
                        needsLearning: false,
                        recognizedName: "高纯度铜管",
                        recognizedUnit: "根",
                        recognizedCategory: "管材"
                    ),
                    .miniCPM
                )
            }
        )

        let outcome = try await pipeline.recognize(rawImageData: Data([0x01]))

        XCTAssertTrue(fallbackCalled, "虽然纸箱向量相似度高达 0.86，但 OCR 文字发生明显冲突，必须否决向量短路并调用 VLM 深度理解")
        XCTAssertEqual(outcome.source, .miniCPM)
        XCTAssertEqual(outcome.result.recognizedName, "高纯度铜管", "必须正确解析出新纸箱上的真实品名，绝不能被旧咖啡纸箱覆盖")
    }

    func testExtractAttributesForNewSKUDidNotCoveredByExistingVector() async throws {
        // 场景：商品建档表单（SKUFormView）拍照填表，即使库里有旧商品纸箱，也必须提取新品属性
        let context = try makeContext()
        let oldSKU = RawMaterialSKU(skuCode: "SKU-OLD", skuName: "旧纸箱物料", categoryName: "旧品类")
        let sample = FeatureSample(sku: oldSKU)
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            ocrEngine: FakeOCREngine(result: VisionOCREngine.OCRResult(
                lines: ["精密轴承 608ZZ"],
                fullText: "精密轴承 608ZZ",
                topCandidateTerms: ["精密轴承"]
            )),
            featureRepository: FakeFeatureSearch(matches: [FeatureMatch(sample: sample, similarity: 0.88)]),
            fallback: { _ in
                return (
                    RecognitionResult(
                        confidence: 0.92,
                        mode: .vision,
                        needsLearning: false,
                        recognizedName: "精密轴承",
                        recognizedUnit: "个",
                        recognizedCategory: "传动件"
                    ),
                    .miniCPM
                )
            }
        )

        let outcome = try await pipeline.extractAttributesForNewSKU(rawImageData: Data([0x01]))

        XCTAssertEqual(outcome.result.recognizedName, "精密轴承")
        XCTAssertEqual(outcome.result.recognizedCategory, "传动件")
        XCTAssertEqual(outcome.matches.count, 0, "建档专属通道不应返回存量冲突向量")
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

private actor FakeOCREngine: VisionOCRProviding {
    private let stubResult: VisionOCREngine.OCRResult

    init(result: VisionOCREngine.OCRResult) {
        self.stubResult = result
    }

    func recognizeText(from imageData: Data) async throws -> VisionOCREngine.OCRResult {
        stubResult
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
