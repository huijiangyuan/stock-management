import Foundation
import Vision
import UIKit

protocol VisionOCRProviding: Actor {
    func recognizeText(from imageData: Data) async throws -> VisionOCREngine.OCRResult
}

/// 端侧 Apple Vision 极速 OCR 识字引擎
/// 利用 iOS 系统原生 VNRecognizeTextRequest 实现离线、毫秒级（15~40ms）、零额外模型内存占用的文字检测与识别。
actor VisionOCREngine: VisionOCRProviding {
    static let shared = VisionOCREngine()

    struct OCRResult: Sendable {
        let lines: [String]
        let fullText: String
        let topCandidateTerms: [String]

        var isEmpty: Bool { lines.isEmpty }
    }

    /// 从 JPEG 图片数据中提取所有可见文本行与关键词
    func recognizeText(from imageData: Data) async throws -> OCRResult {
        guard let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage else {
            return OCRResult(lines: [], fullText: "", topCandidateTerms: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(lines: [], fullText: "", topCandidateTerms: []))
                    return
                }

                var lines: [String] = []
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first {
                        let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            lines.append(text)
                        }
                    }
                }

                let fullText = lines.joined(separator: " ")
                let terms = Self.extractKeyTerms(from: lines)
                continuation.resume(returning: OCRResult(lines: lines, fullText: fullText, topCandidateTerms: terms))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 判定图片中识别到的文字是否与候选商品名称存在明确匹配（包含或高度重合）
    nonisolated static func isTextMatching(ocrFullText: String, candidateSKUName: String) -> Bool {
        let cleanText = ocrFullText.replacingOccurrences(of: " ", with: "").lowercased()
        let cleanName = candidateSKUName.replacingOccurrences(of: " ", with: "").lowercased()
        guard !cleanName.isEmpty, !cleanText.isEmpty else { return false }

        // 1. OCR 文本直接包含完整商品名
        if cleanText.contains(cleanName) {
            return true
        }

        // 2. 若商品名较长（>=4字符），提取核心词比对
        if cleanName.count >= 4 {
            let halfLen = cleanName.count / 2
            let prefixPart = String(cleanName.prefix(halfLen + 1))
            let suffixPart = String(cleanName.suffix(halfLen + 1))
            if cleanText.contains(prefixPart) || cleanText.contains(suffixPart) {
                return true
            }
        }

        return false
    }

    /// 判定图片中识别到的文字是否与候选商品名称存在明显冲突（外包装相似但文字完全不同）
    nonisolated static func isTextConflicting(ocrFullText: String, ocrTerms: [String], candidateSKUName: String) -> Bool {
        let cleanText = ocrFullText.replacingOccurrences(of: " ", with: "").lowercased()
        let cleanName = candidateSKUName.replacingOccurrences(of: " ", with: "").lowercased()

        // 如果图片没有识别出任何文字，不算冲突（属于纯无字工件）
        guard !cleanText.isEmpty, !cleanName.isEmpty else { return false }

        // 如果已经命中匹配，则不属于冲突
        if isTextMatching(ocrFullText: ocrFullText, candidateSKUName: candidateSKUName) {
            return false
        }

        // 图片中提取到了清晰的商品词/品牌词（长度 >= 2 的有效中文字词），且与候选 SKU 完全不相交
        let hasDistinctTerms = ocrTerms.contains { term in
            term.count >= 2 && !cleanName.contains(term.lowercased())
        }

        return hasDistinctTerms
    }

    /// 从识别出的文本行中清洗并提取可能的品名/规格/品牌关键词
    private static func extractKeyTerms(from lines: [String]) -> [String] {
        var terms: [String] = []
        let blacklist: Set<String> = ["合格", "检验", "生产日期", "保质期", "净含量", "电话", "地址", "执行标准", "配料", "配料表", "注意事项"]

        for line in lines {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.count >= 2 && clean.count <= 20 && !blacklist.contains(clean) {
                terms.append(clean)
            }
        }
        return terms
    }
}
