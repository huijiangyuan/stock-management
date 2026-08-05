import Foundation
import os
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
    private let vectorCandidateThreshold: Float
    private let vectorAutoSelectionThreshold: Float

    init(
        context: ModelContext,
        imageProcessor: any CapturedImageProcessing = CapturedImageProcessor.shared,
        embeddingEngine: any ImageEmbeddingProviding = MobileCLIPEmbeddingEngine.shared,
        featureRepository: (any FeatureSearching)? = nil,
        vectorCandidateThreshold: Float = 0.65,
        vectorAutoSelectionThreshold: Float = 0.85,
        fallback: Fallback? = nil
    ) {
        self.context = context
        self.imageProcessor = imageProcessor
        self.embeddingEngine = embeddingEngine
        self.featureRepository = featureRepository ?? FeatureRepository(context: context)
        self.vectorCandidateThreshold = vectorCandidateThreshold
        self.vectorAutoSelectionThreshold = vectorAutoSelectionThreshold
        self.fallback = fallback ?? { data in
            await Self.defaultFallback(imageData: data, context: context)
        }
    }

    func recognize(rawImageData: Data) async throws -> VisionRecognitionOutcome {
        let recognitionID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        AppLogger.shared.log(
            level: .info,
            category: .ai,
            message: "开始 AI 图片识别流水线",
            details: "id=\(recognitionID), input=\(rawImageData.count / 1_024)KB, availableMemory=\(os_proc_available_memory() / 1_048_576)MB"
        )
        let processedImage = try await imageProcessor.process(rawImageData)
        try Task.checkCancellation()
        AppLogger.shared.log(
            level: .info,
            category: .ai,
            message: "相机图片预处理完成",
            details: "id=\(recognitionID), size=\(processedImage.pixelWidth)x\(processedImage.pixelHeight), elapsed=\(Self.elapsed(since: startedAt))s"
        )

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
            try Task.checkCancellation()
            AppLogger.shared.log(
                level: .info,
                category: .ai,
                message: "MobileCLIP 图片向量与 Top-3 检索完成",
                details: "id=\(recognitionID), dimension=\(generated.dimension), candidates=\(matches.count), elapsed=\(Self.elapsed(since: startedAt))s"
            )
        } catch {
            if error is CancellationError { throw error }
            AppLogger.shared.log(
                level: .warning,
                category: .ai,
                message: "轻量图片向量阶段失败，继续使用 VLM 兜底",
                details: "id=\(recognitionID), error=\(error.localizedDescription)"
            )
        }

        if let best = matches.first, best.similarity >= vectorCandidateThreshold,
           let sku = best.sample.sku {
            let result = RecognitionResult(
                sku: sku,
                packagingUnit: best.sample.unit ?? sku.packagingUnits.first,
                confidence: Double(best.similarity),
                mode: .vision,
                needsLearning: best.similarity < vectorAutoSelectionThreshold,
                recognizedName: sku.skuName
            )
            AppLogger.shared.log(
                level: .info,
                category: .ai,
                message: best.similarity >= vectorAutoSelectionThreshold
                    ? "本地图片向量高置信度命中商品"
                    : "本地图片向量返回候选，等待人工确认",
                details: "id=\(recognitionID), sku=\(sku.skuCode), similarity=\(best.similarity), candidateThreshold=\(vectorCandidateThreshold), autoThreshold=\(vectorAutoSelectionThreshold)"
            )
            return VisionRecognitionOutcome(
                recognitionID: recognitionID,
                result: result,
                processedImage: processedImage,
                embedding: embedding,
                matches: matches,
                source: .vector
            )
        }

        try Task.checkCancellation()
        let (fallbackResult, source) = await fallback(processedImage.jpegData)
        try Task.checkCancellation()
        var resolved = fallbackResult
        if resolved.sku == nil, let name = resolved.recognizedName {
            resolved.sku = try matchSKU(by: name)
            if let sku = resolved.sku {
                resolved.packagingUnit = sku.packagingUnits.first
            }
        }

        return VisionRecognitionOutcome(
            recognitionID: recognitionID,
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

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
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
