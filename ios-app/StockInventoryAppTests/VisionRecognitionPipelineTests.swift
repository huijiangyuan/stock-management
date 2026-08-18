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
            fallback: { _, _ in
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
            fallback: { _, _ in
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
        var passedHint: String?
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
            fallback: { _, hint in
                fallbackCalled = true
                passedHint = hint
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
        XCTAssertEqual(passedHint, "高纯度铜管", "应将 OCR 提取出的关键词传递给大模型作为先验提速")
        XCTAssertEqual(outcome.source, .miniCPM)
        XCTAssertEqual(outcome.result.recognizedName, "高纯度铜管", "必须正确解析出新纸箱上的真实品名，绝不能被旧咖啡纸箱覆盖")
    }

    func testDicosHomoglyphAndCategoryAutoInference() async throws {
        // 场景：OCR 提取到了“德克上”，VLM 未就绪时，系统自动纠正为“德克士”并自动推理填充“食品餐饮”分类和“份”单位
        let context = try makeContext()
        let pipeline = VisionRecognitionPipeline(
            context: context,
            imageProcessor: FakeImageProcessor(),
            embeddingEngine: FakeEmbeddingEngine(),
            ocrEngine: FakeOCREngine(result: VisionOCREngine.OCRResult(
                lines: ["德克上香辣鸡腿堡"],
                fullText: "德克上香辣鸡腿堡",
                topCandidateTerms: ["德克上香辣鸡腿堡"]
            )),
            featureRepository: FakeFeatureSearch(matches: []),
            fallback: { _, hint in
                // 模拟大模型未能识别出分类（只输出了生文本）
                return (
                    RecognitionResult(
                        confidence: 0.8,
                        mode: .vision,
                        needsLearning: false,
                        recognizedName: "德克上香辣鸡腿堡"
                    ),
                    .miniCPM
                )
            }
        )

        let outcome = try await pipeline.extractAttributesForNewSKU(rawImageData: Data([0x01]))

        XCTAssertEqual(outcome.result.recognizedName, "德克士香辣鸡腿堡", "形近字‘德克上’应自动纠偏为‘德克士’")
        XCTAssertEqual(outcome.result.displayCategoryName, "食品餐饮", "应根据‘德克士/汉堡’自动推理填充‘食品餐饮’品类")
        XCTAssertEqual(outcome.result.displayUnitName, "份", "应自动推断‘份’为基准单位")
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
