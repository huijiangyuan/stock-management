import Foundation
import SwiftData

/// 单次拍照识别流水线：规范化图片 → MobileCLIP Top-3 → 高置信度直返 → MiniCPM/云端兜底。
/// 整个编排限定在 MainActor，耗时图片与 Core ML 操作分别由 actor 串行执行。
@MainActor
final class VisionRecognitionPipeline {
    typealias Fallback = @MainActor (Data) async -> (RecognitionResult, VisionRecognitionSource)

    private let imageProcessor: any CapturedImageProcessing
    private let embeddingEngine: any ImageEmbeddingProviding
    private let featureRepository: any FeatureSearching
    private let context: ModelContext
    private let fallback: Fallback
    private let vectorAcceptanceThreshold: Float

    init(
        context: ModelContext,
        imageProcessor: any CapturedImageProcessing = CapturedImageProcessor.shared,
        embeddingEngine: any ImageEmbeddingProviding = MobileCLIPEmbeddingEngine.shared,
        featureRepository: (any FeatureSearching)? = nil,
        vectorAcceptanceThreshold: Float = 0.65,
        fallback: Fallback? = nil
    ) {
        self.context = context
        self.imageProcessor = imageProcessor
        self.embeddingEngine = embeddingEngine
        self.featureRepository = featureRepository ?? FeatureRepository(context: context)
        self.vectorAcceptanceThreshold = vectorAcceptanceThreshold
        self.fallback = fallback ?? { data in
            await Self.defaultFallback(imageData: data, context: context)
        }
    }

    func recognize(rawImageData: Data) async throws -> VisionRecognitionOutcome {
        AppLogger.shared.log(level: .info, category: .ai, message: "开始 AI 图片识别流水线")
        let processedImage = try await imageProcessor.process(rawImageData)

        var embedding: ImageEmbedding?
        var matches: [FeatureMatch] = []
        do {
            let generated = try await embeddingEngine.embed(imageData: processedImage.jpegData)
            embedding = generated
            matches = try featureRepository.topMatches(
                queryVector: generated.values,
                modelVersion: generated.modelVersion,
                topK: 12
            )
            matches = Self.uniqueSKUMatches(matches, limit: 3)
        } catch {
            AppLogger.shared.log(
                level: .warning,
                category: .ai,
                message: "轻量图片向量阶段失败，继续使用 VLM 兜底",
                details: error.localizedDescription
            )
        }

        if let best = matches.first, best.similarity >= vectorAcceptanceThreshold,
           let sku = best.sample.sku {
            let result = RecognitionResult(
                sku: sku,
                packagingUnit: best.sample.unit ?? sku.packagingUnits.first,
                confidence: Double(best.similarity),
                mode: .vision,
                needsLearning: false,
                recognizedName: sku.skuName
            )
            AppLogger.shared.log(
                level: .info,
                category: .ai,
                message: "本地图片向量命中商品",
                details: "sku=\(sku.skuCode), similarity=\(best.similarity)"
            )
            return VisionRecognitionOutcome(
                result: result,
                processedImage: processedImage,
                embedding: embedding,
                matches: matches,
                source: .vector
            )
        }

        let (fallbackResult, source) = await fallback(processedImage.jpegData)
        var resolved = fallbackResult
        if resolved.sku == nil, let name = resolved.recognizedName {
            resolved.sku = try matchSKU(by: name)
            if let sku = resolved.sku {
                resolved.packagingUnit = sku.packagingUnits.first
            }
        }

        return VisionRecognitionOutcome(
            result: resolved,
            processedImage: processedImage,
            embedding: embedding,
            matches: matches,
            source: source
        )
    }

    private func matchSKU(by name: String) throws -> RawMaterialSKU? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let skus = try context.fetch(FetchDescriptor<RawMaterialSKU>())
        return skus.first {
            $0.skuName.localizedCaseInsensitiveContains(normalized)
                || normalized.localizedCaseInsensitiveContains($0.skuName)
        }
    }

    private static func uniqueSKUMatches(_ matches: [FeatureMatch], limit: Int) -> [FeatureMatch] {
        var seenSKUIds = Set<String>()
        return matches.filter { match in
            guard let skuID = match.sample.sku?.skuId else { return false }
            return seenSKUIds.insert(skuID).inserted
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func defaultFallback(
        imageData: Data,
        context: ModelContext
    ) async -> (RecognitionResult, VisionRecognitionSource) {
        let settings = VisionSettings.shared

        if (settings.preferOnDevice || !settings.cloudReady),
           !OnDeviceVisionEngine.shared.loadSuccess {
            await ModelManager.shared.ensureLoaded()
        }
        let onDeviceReady = OnDeviceVisionEngine.shared.onDeviceUsable

        if settings.preferOnDevice {
            if onDeviceReady {
                return (await OnDeviceVisionEngine.shared.recognize(imageData: imageData), .miniCPM)
            }
            if settings.cloudReady {
                let result = await CloudVisionEngine().recognize(
                    RecognitionInput(visionImage: imageData),
                    context: context
                )
                return (result, .cloud)
            }
        } else {
            if settings.cloudReady {
                let result = await CloudVisionEngine().recognize(
                    RecognitionInput(visionImage: imageData),
                    context: context
                )
                return (result, .cloud)
            }
            if onDeviceReady {
                return (await OnDeviceVisionEngine.shared.recognize(imageData: imageData), .miniCPM)
            }
        }

        AppLogger.shared.log(
            level: .error,
            category: .ai,
            message: "没有可用的视觉识别兜底引擎",
            details: OnDeviceVisionEngine.shared.unavailableReason
        )
        return (
            RecognitionResult(confidence: 0, mode: .vision, needsLearning: true),
            .unavailable
        )
    }
}
