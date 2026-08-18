import Foundation
import os
import SwiftData

/// 单次拍照识别流水线：规范化图片 → OCR 识字与 MobileCLIP 向量 → 多模态交叉验证 → MiniCPM/云端兜底。
/// 整个编排限定在 MainActor，耗时图片、OCR 与 Core ML 操作分别由 actor 串行执行。
@MainActor
final class VisionRecognitionPipeline {
    typealias Fallback = @MainActor (Data) async -> (RecognitionResult, VisionRecognitionSource)

    private let imageProcessor: any CapturedImageProcessing
    private let embeddingEngine: any ImageEmbeddingProviding
    private let ocrEngine: any VisionOCRProviding
    private let featureRepository: any FeatureSearching
    private let context: ModelContext
    private let fallback: Fallback
    private let vectorCandidateThreshold: Float
    private let vectorAutoSelectionThreshold: Float

    init(
        context: ModelContext,
        imageProcessor: any CapturedImageProcessing = CapturedImageProcessor.shared,
        embeddingEngine: any ImageEmbeddingProviding = MobileCLIPEmbeddingEngine.shared,
        ocrEngine: any VisionOCRProviding = VisionOCREngine.shared,
        featureRepository: (any FeatureSearching)? = nil,
        vectorCandidateThreshold: Float = 0.70,
        vectorAutoSelectionThreshold: Float = 0.90,
        fallback: Fallback? = nil
    ) {
        self.context = context
        self.imageProcessor = imageProcessor
        self.embeddingEngine = embeddingEngine
        self.ocrEngine = ocrEngine
        self.featureRepository = featureRepository ?? FeatureRepository(context: context)
        self.vectorCandidateThreshold = vectorCandidateThreshold
        self.vectorAutoSelectionThreshold = vectorAutoSelectionThreshold
        self.fallback = fallback ?? { data in
            await Self.defaultFallback(imageData: data, context: context)
        }
    }

    /// 出入库标准识别流程：OCR + 向量多模态双重验证，未命中或文字冲突时自动流转至 MiniCPM-V 深度图文理解。
    func recognize(rawImageData: Data) async throws -> VisionRecognitionOutcome {
        let recognitionID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        AppLogger.shared.log(
            level: .info,
            category: .ai,
            message: "开始 AI 多模态图片识别流水线",
            details: "id=\(recognitionID), input=\(rawImageData.count / 1_024)KB, availableMemory=\(os_proc_available_memory() / 1_048_576)MB"
        )
        let processedImage = try await imageProcessor.process(rawImageData)
        try Task.checkCancellation()

        // 1. 端侧 Apple Vision 极速 OCR 提取图中文字（毫秒级，无内存负担）
        var ocrResult = VisionOCREngine.OCRResult(lines: [], fullText: "", topCandidateTerms: [])
        do {
            ocrResult = try await ocrEngine.recognizeText(from: processedImage.jpegData)
            AppLogger.shared.log(
                level: .info,
                category: .ai,
                message: "端侧 Apple Vision OCR 识字完成",
                details: "id=\(recognitionID), lines=\(ocrResult.lines.count), text=\(ocrResult.fullText.prefix(60))"
            )
        } catch {
            AppLogger.shared.log(
                level: .warning,
                category: .ai,
                message: "端侧 OCR 识字跳过",
                details: "id=\(recognitionID), error=\(error.localizedDescription)"
            )
        }

        // 2. 提取 MobileCLIP 图片特征向量并检索候选
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

        // 3. 多模态交叉验证（OCR 文本 + 视觉向量双重判定，杜绝同类纸箱误判）
        if let best = matches.first, let sku = best.sample.sku {
            let candidateName = sku.skuName
            let hasOCR = !ocrResult.fullText.isEmpty

            // 规则 A：OCR 文本明确包含候选商品名，且向量相似度较高 -> 高置信度直接命中已有商品
            if hasOCR && VisionOCREngine.isTextMatching(ocrFullText: ocrResult.fullText, candidateSKUName: candidateName) && best.similarity >= vectorCandidateThreshold {
                let confidence = Double(max(best.similarity, 0.92))
                let result = RecognitionResult(
                    sku: sku,
                    packagingUnit: best.sample.unit ?? sku.packagingUnits.first,
                    confidence: confidence,
                    mode: .vision,
                    needsLearning: false,
                    recognizedName: candidateName
                )
                AppLogger.shared.log(
                    level: .info,
                    category: .ai,
                    message: "多模态双重验证通过：OCR 文字与图片向量一致命中商品",
                    details: "id=\(recognitionID), sku=\(sku.skuCode), name=\(candidateName), similarity=\(best.similarity)"
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

            // 规则 B：图片中存在明确文字，但与候选商品名发生冲突（如都是纸箱但印着不同商品） -> 坚决否决向量短路，强制走 VLM
            if hasOCR && VisionOCREngine.isTextConflicting(ocrFullText: ocrResult.fullText, ocrTerms: ocrResult.topCandidateTerms, candidateSKUName: candidateName) {
                AppLogger.shared.log(
                    level: .info,
                    category: .ai,
                    message: "多模态检测到外包装相似但文字冲突，否决向量短路，流转至 VLM 深度图文理解",
                    details: "id=\(recognitionID), ocrText=[\(ocrResult.fullText.prefix(30))], candidate=[\(candidateName)], similarity=\(best.similarity)"
                )
                // 不在此处 return，继续向下流转至 MiniCPM-V 4.6 深度解析
            } else if !hasOCR && best.similarity >= vectorAutoSelectionThreshold {
                // 规则 C：纯无字工件在极高视觉相似度（>= 0.90）下才允许直返
                let result = RecognitionResult(
                    sku: sku,
                    packagingUnit: best.sample.unit ?? sku.packagingUnits.first,
                    confidence: Double(best.similarity),
                    mode: .vision,
                    needsLearning: false,
                    recognizedName: candidateName
                )
                AppLogger.shared.log(
                    level: .info,
                    category: .ai,
                    message: "纯视觉极高置信度命中无字物料",
                    details: "id=\(recognitionID), sku=\(sku.skuCode), similarity=\(best.similarity)"
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
        }

        // 4. 深度图文理解：调用 MiniCPM-V 4.6 端侧多模态模型（或云端 VLM 兜底）
        try Task.checkCancellation()
        let (fallbackResult, source) = await fallback(processedImage.jpegData)
        try Task.checkCancellation()
        var resolved = fallbackResult

        // 若大模型未能输出品名，但 OCR 提取到了高频品名词，补充为品名兜底
        if (resolved.recognizedName == nil || resolved.recognizedName?.isEmpty == true),
           let topTerm = ocrResult.topCandidateTerms.first {
            resolved.recognizedName = topTerm
        }

        // 在本地已有商品库中模糊比对品名，若匹配已有商品则绑定，否则作为新商品
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

    /// 商品物料建档专用 AI 解析：直接调用多模态 VLM + OCR 提取当前物料属性，绝不被已有商品向量覆盖。
    func extractAttributesForNewSKU(rawImageData: Data) async throws -> VisionRecognitionOutcome {
        let recognitionID = String(UUID().uuidString.prefix(8))
        let processedImage = try await imageProcessor.process(rawImageData)
        try Task.checkCancellation()

        // 1. OCR 提取文本
        let ocrResult = (try? await ocrEngine.recognizeText(from: processedImage.jpegData)) ?? VisionOCREngine.OCRResult(lines: [], fullText: "", topCandidateTerms: [])

        // 2. 计算当前图片特征向量（用于建档保存样本）
        let embedding = try? await embeddingEngine.embed(imageData: processedImage.jpegData)

        // 3. 直接调用端侧 MiniCPM-V / 云端 VLM 进行物料属性结构化解析
        let (fallbackResult, source) = await fallback(processedImage.jpegData)
        var resolved = fallbackResult

        if (resolved.recognizedName == nil || resolved.recognizedName?.isEmpty == true),
           let topTerm = ocrResult.topCandidateTerms.first {
            resolved.recognizedName = topTerm
        }

        return VisionRecognitionOutcome(
            recognitionID: recognitionID,
            result: resolved,
            processedImage: processedImage,
            embedding: embedding,
            matches: [],
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

        // MobileCLIP 未命中后必须先尝试 MiniCPM-V；云端只在模型缺失或
        // 内存准入未通过时兜底，不能通过偏好设置绕过端侧验证链路。
        if !OnDeviceVisionEngine.shared.loadSuccess {
            await ModelManager.shared.ensureLoaded()
        }
        if OnDeviceVisionEngine.shared.onDeviceUsable {
            return (await OnDeviceVisionEngine.shared.recognize(imageData: imageData), .miniCPM)
        }
        if settings.cloudReady {
            let result = await CloudVisionEngine().recognize(
                RecognitionInput(visionImage: imageData),
                context: context
            )
            return (result, .cloud)
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
