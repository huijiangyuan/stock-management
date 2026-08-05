import SwiftData
import XCTest
@testable import StockInventoryApp

@MainActor
final class FeatureRepositoryTests: XCTestCase {
    func testTopMatchesReturnsDescendingCompatibleVectorsOnly() throws {
        let context = try makeContext()
        let closeSKU = RawMaterialSKU(skuCode: "CLOSE", skuName: "近似商品", categoryName: "测试")
        let farSKU = RawMaterialSKU(skuCode: "FAR", skuName: "远距离商品", categoryName: "测试")
        let incompatibleSKU = RawMaterialSKU(skuCode: "OLD", skuName: "旧模型商品", categoryName: "测试")
        [closeSKU, farSKU, incompatibleSKU].forEach(context.insert)
        context.insert(makeSample(vector: [0.99, 0.01], version: "test-v1", sku: closeSKU))
        context.insert(makeSample(vector: [0.2, 0.8], version: "test-v1", sku: farSKU))
        context.insert(makeSample(vector: [1, 0], version: "test-v0", sku: incompatibleSKU))
        try context.save()

        let matches = try FeatureRepository(context: context).topMatches(
            queryVector: try LocalFeatureEngine.normalized([1, 0]),
            modelVersion: "test-v1",
            topK: 3
        )

        XCTAssertEqual(matches.map { $0.sample.sku?.skuCode }, ["CLOSE", "FAR"])
        XCTAssertGreaterThan(matches[0].similarity, matches[1].similarity)
    }

    func testTopMatchesSkipsCorruptVectorWithoutCrashing() throws {
        let context = try makeContext()
        let sku = RawMaterialSKU(skuCode: "BAD", skuName: "损坏样本", categoryName: "测试")
        context.insert(sku)
        context.insert(FeatureSample(
            visionEmbedding: Data([0x01]),
            visionModelVersion: "test-v1",
            visionVectorDimension: 2,
            sku: sku
        ))
        try context.save()

        let matches = try FeatureRepository(context: context).topMatches(
            queryVector: [1, 0],
            modelVersion: "test-v1",
            topK: 3
        )

        XCTAssertTrue(matches.isEmpty)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            schema: StockModelContainer.schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: StockModelContainer.schema, configurations: [configuration]))
    }

    private func makeSample(vector: [Float], version: String, sku: RawMaterialSKU) -> FeatureSample {
        FeatureSample(
            visionEmbedding: LocalFeatureEngine.toData(vector),
            visionModelVersion: version,
            visionVectorDimension: vector.count,
            sku: sku
        )
    }
}
