import Foundation
import SwiftData
import Accelerate

/// 端侧本地特征比对引擎 (Feature Embedding & Similarity Matching)
/// 对应方案文档 DDL: material_feature_sample 与 端侧向量检索 (SQLite-vec / Cosine Similarity)
struct LocalFeatureEngine {

    enum VectorError: LocalizedError, Equatable {
        case invalidByteCount(Int)
        case emptyVector
        case nonFiniteValue
        case zeroNorm

        var errorDescription: String? {
            switch self {
            case .invalidByteCount(let count):
                return "向量数据长度 \(count) 不是 Float32 字节数的整数倍"
            case .emptyVector:
                return "向量不能为空"
            case .nonFiniteValue:
                return "向量包含 NaN 或无穷值"
            case .zeroNorm:
                return "向量范数为零"
            }
        }
    }

    // MARK: - 向量转换工具

    /// 将 [Float] 数组转成 Data 字节串 (Float32)
    static func toData(_ array: [Float]) -> Data {
        array.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    /// 从 Data 字节串安全解析 [Float] 数组。
    /// SwiftData 中的历史数据可能损坏，必须先验证字节数，再逐项复制，避免未对齐内存访问。
    static func decodeVector(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.stride) else {
            throw VectorError.invalidByteCount(data.count)
        }

        let vector = data.withUnsafeBytes { rawBuffer -> [Float] in
            stride(from: 0, to: rawBuffer.count, by: MemoryLayout<Float>.stride).map { offset in
                var value: Float = 0
                withUnsafeMutableBytes(of: &value) { destination in
                    destination.copyBytes(from: rawBuffer[offset..<(offset + MemoryLayout<Float>.stride)])
                }
                return value
            }
        }

        guard vector.allSatisfy({ $0.isFinite }) else {
            throw VectorError.nonFiniteValue
        }
        return vector
    }

    /// 兼容旧调用点；新检索路径使用 throwing API 暴露数据损坏。
    static func toFloatArray(_ data: Data) -> [Float] {
        (try? decodeVector(data)) ?? []
    }

    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty else { throw VectorError.emptyVector }
        guard vector.allSatisfy({ $0.isFinite }) else { throw VectorError.nonFiniteValue }

        var squaredNorm: Float = 0
        vDSP_svesq(vector, 1, &squaredNorm, vDSP_Length(vector.count))
        guard squaredNorm.isFinite, squaredNorm > 0 else { throw VectorError.zeroNorm }

        var scale = 1 / sqrt(squaredNorm)
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &output, 1, vDSP_Length(vector.count))
        return output
    }

    /// 计算两个 [Float] 向量的余弦相似度 (Cosine Similarity)
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count,
              !a.isEmpty,
              a.allSatisfy({ $0.isFinite }),
              b.allSatisfy({ $0.isFinite }) else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denom = sqrt(normA) * sqrt(normB)
        guard denom.isFinite, denom > 0 else { return 0 }
        let similarity = dot / denom
        return similarity.isFinite ? min(1, max(-1, similarity)) : 0
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
