import Foundation
import SwiftData

/// 云端 VLM 视觉识别引擎：拍照 → 调服务商 → 模糊匹配本地 SKU → 预填入库字段。
/// 识别不准（低置信度 / 未命中）一律标记 needsLearning，由 UI 转人工确认，绝不静默错账。
struct CloudVisionEngine: RecognitionEngine {
    let mode: RecognitionMode = .vision

    static let prompt = """
你是餐饮原材料库存识别助手。请看图识别包装上的原材料，并只返回一个 JSON 对象（不要多余解释）：
{
  "sku_name": "标准品名，如 精品肥牛卷",
  "unit_name": "规格，如 大箱 / 中盒 / 散包（不确定留空）",
  "production_date": "生产日期 yyyy-MM-dd（看图，不确定留空）",
  "expiration_date": "保质期截止 yyyy-MM-dd（看图，不确定留空）",
  "confidence": 0.0到1.0 你对该识别的把握
}
"""

    func recognize(_ input: RecognitionInput, context: ModelContext) async -> RecognitionResult {
        guard let img = input.visionImage else {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true)
        }
        let settings = VisionSettings.shared
        guard !settings.localOnly, let key = settings.apiKey, !key.isEmpty else {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true)
        }
        let provider: CloudVisionProvider = settings.provider == .anthropic ? AnthropicProvider() : DashScopeProvider()
        do {
            let raw = try await provider.recognize(image: img, prompt: Self.prompt)
            let match = Self.matchSKU(name: raw.skuName, context: context)
            return Self.buildResult(raw: raw, sku: match)
        } catch {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true)
        }
    }

    /// 本地 SKU 双向模糊匹配（名称互相包含即视为命中）
    static func matchSKU(name: String?, context: ModelContext) -> RawMaterialSKU? {
        guard let name, !name.isEmpty else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<RawMaterialSKU>()
        guard let all = try? context.fetch(descriptor) else { return nil }
        return all.first(where: {
            $0.skuName.localizedCaseInsensitiveContains(n) || n.localizedCaseInsensitiveContains($0.skuName)
        })
    }

    static func buildResult(raw: VisionRawResult, sku: RawMaterialSKU?) -> RecognitionResult {
        let conf = raw.confidence
        let prod = parseDate(raw.productionDate)
        var exp = parseDate(raw.expirationDate)
        if exp == nil, let p = prod, let sku, sku.shelfLifeDays > 0 {
            exp = Calendar.current.date(byAdding: .day, value: sku.shelfLifeDays, to: p)
        }
        let needsLearning = sku == nil || conf < 0.6
        let unit = sku?.packagingUnits.first
        return RecognitionResult(sku: sku, packagingUnit: unit, confidence: conf,
                                 mode: .vision, needsLearning: needsLearning,
                                 recognizedName: raw.skuName, productionDate: prod, expirationDate: exp)
    }

    /// 宽松日期解析：优先 yyyy-MM-dd，兼容 yyyy.MM.dd / yyyy/MM/dd
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let fmts = ["yyyy-MM-dd", "yyyy.MM.dd", "yyyy/MM/dd"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
