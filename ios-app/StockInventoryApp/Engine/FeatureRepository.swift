import Foundation
import SwiftData

struct FeatureMatch {
    let sample: FeatureSample
    let similarity: Float
}

@MainActor
protocol FeatureSearching: AnyObject {
    func topMatches(queryVector: [Float], modelVersion: String, topK: Int) throws -> [FeatureMatch]
}

@MainActor
final class FeatureRepository: FeatureSearching {
    enum RepositoryError: LocalizedError {
        case invalidQueryVector

        var errorDescription: String? { "查询图片向量为空或包含无效值" }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func topMatches(
        queryVector: [Float],
        modelVersion: String,
        topK: Int = 3
    ) throws -> [FeatureMatch] {
        guard !queryVector.isEmpty, queryVector.allSatisfy({ $0.isFinite }) else {
            throw RepositoryError.invalidQueryVector
        }

        let samples = try context.fetch(FetchDescriptor<FeatureSample>())
        var matches: [FeatureMatch] = []
        matches.reserveCapacity(samples.count)

        for sample in samples {
            guard sample.visionModelVersion == modelVersion,
                  sample.visionVectorDimension == queryVector.count,
                  let data = sample.visionEmbedding else { continue }
            do {
                let vector = try LocalFeatureEngine.decodeVector(data)
                let similarity = LocalFeatureEngine.cosineSimilarity(queryVector, vector)
                matches.append(FeatureMatch(sample: sample, similarity: similarity))
            } catch {
                AppLogger.shared.log(
                    level: .warning,
                    category: .store,
                    message: "跳过损坏的图片特征样本",
                    details: "sampleId=\(sample.sampleId), error=\(error.localizedDescription)"
                )
            }
        }

        return matches
            .sorted { $0.similarity > $1.similarity }
            .prefix(max(0, topK))
            .map { $0 }
    }

    @discardableResult
    func saveSample(
        image: ProcessedCapturedImage,
        embedding: ImageEmbedding,
        angleTag: String = "FRONT",
        ocrText: String? = nil,
        unit: PackagingUnit?,
        sku: RawMaterialSKU
    ) throws -> FeatureSample {
        let sampleID = UUID().uuidString
        let imageURL = try featureImageURL(sampleID: sampleID)
        try image.jpegData.write(to: imageURL, options: .atomic)

        let sample = FeatureSample(
            sampleId: sampleID,
            angleTag: angleTag,
            ocrTextContent: ocrText,
            sampleImagePath: imageURL.path,
            visionEmbedding: LocalFeatureEngine.toData(embedding.values),
            visionModelVersion: embedding.modelVersion,
            visionVectorDimension: embedding.dimension,
            unit: unit,
            sku: sku
        )
        context.insert(sample)

        do {
            try context.save()
            return sample
        } catch {
            context.delete(sample)
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

    private func featureImageURL(sampleID: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("FeatureSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(sampleID).jpg")
    }
}
