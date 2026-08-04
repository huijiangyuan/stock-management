import Foundation
import SwiftData
import Accelerate

/// 端侧本地特征比对引擎 (Feature Embedding & Similarity Matching)
/// 对应方案文档 DDL: material_feature_sample 与 端侧向量检索 (SQLite-vec / Cosine Similarity)
struct LocalFeatureEngine {

    // MARK: - 向量转换工具

    /// 将 [Float] 数组转成 Data 字节串 (Float32)
    static func toData(_ array: [Float]) -> Data {
        return array.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 从 Data 字节串解析 [Float] 数组
    static func toFloatArray(_ data: Data) -> [Float] {
        return data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
    }

    /// 计算两个 [Float] 向量的余弦相似度 (Cosine Similarity)
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// 基于文本字词特征哈希生成固定 512 维 Float 模拟 Embedding（端侧离线文本向量补丁）
    static func generateTextEmbedding(_ text: String) -> [Float] {
        var vec = [Float](repeating: 0, count: 512)
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty else { return vec }
        
        for (i, byte) in utf8.enumerated() {
            let idx = (Int(byte) * 31 + i * 17) % 512
            vec[idx] += 1.0
        }
        
        // 归一化 (L2 Norm)
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, 512)
        let sqrtNorm = sqrt(norm)
        if sqrtNorm > 0 {
            var scale = 1.0 / sqrtNorm
            vDSP_vsmul(vec, 1, &scale, &vec, 1, 512)
        }
        return vec
    }

    // MARK: - 特征样本检索

    struct MatchResult {
        let sample: FeatureSample
        let similarity: Float
    }

    /// 在本地特征样本库中搜索最相似的 SKU 规格
    static func searchBestMatch(
        ocrText: String?,
        queryEmbedding: [Float]? = nil,
        context: ModelContext,
        topK: Int = 1
    ) -> MatchResult? {
        let descriptor = FetchDescriptor<FeatureSample>()
        guard let samples = try? context.fetch(descriptor), !samples.isEmpty else {
            return nil
        }

        var bestMatch: FeatureSample? = nil
        var highestScore: Float = 0

        // 如果传入了 queryEmbedding，进行余弦相似度匹配
        if let queryVec = queryEmbedding, !queryVec.isEmpty {
            for sample in samples {
                if let visionData = sample.visionEmbedding {
                    let sampleVec = toFloatArray(visionData)
                    let sim = cosineSimilarity(queryVec, sampleVec)
                    if sim > highestScore {
                        highestScore = sim
                        bestMatch = sample
                    }
                }
            }
        }

        // 如果文本符合且目前得分低，尝试 OCR 文本匹配
        if let text = ocrText, !text.isEmpty {
            let queryTextVec = generateTextEmbedding(text)
            for sample in samples {
                let sampleText = sample.ocrTextContent ?? sample.sku?.skuName ?? ""
                if !sampleText.isEmpty {
                    let sampleTextVec = generateTextEmbedding(sampleText)
                    let textSim = cosineSimilarity(queryTextVec, sampleTextVec)
                    if textSim > highestScore {
                        highestScore = textSim
                        bestMatch = sample
                    }
                }
            }
        }

        guard let match = bestMatch, highestScore > 0.5 else { return nil }
        return MatchResult(sample: match, similarity: highestScore)
    }
}
