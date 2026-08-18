import Foundation
import SwiftData

/// 云端 VLM 视觉识别引擎：拍照 → 调服务商 → 模糊匹配本地 SKU → 预填入库字段。
/// 识别不准（低置信度 / 未命中）一律标记 needsLearning，由 UI 转人工确认，绝不静默错账。
struct CloudVisionEngine: RecognitionEngine {
    let mode: RecognitionMode = .vision

    static let prompt = """
    你是智能库存与商品物料识别助手。请看图识别包装上的商品，并直接返回单行紧凑 JSON（不要多余解释）：
    {
      "sku_name": "标准品名，如 精品肥牛卷 / 502胶水",
      "unit_name": "规格单位，如 箱 / 盒 / 瓶 / 包 / 个 / kg",
      "category_name": "品类，如 食品 / 五金 / 日化 / 耗材",
      "shelf_life_days": 365,
      "barcode": "条形码（若可见）",
      "production_date": "生产日期 yyyy-MM-dd",
      "expiration_date": "到期日期 yyyy-MM-dd",
      "confidence": 0.95
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
            await MainActor.run {
                AppLogger.shared.log(
                    level: .error,
                    category: .network,
                    message: "云端 VLM 识别失败",
                    details: error.localizedDescription
                )
            }
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
        let shelfLife = raw.shelfLifeDays ?? sku?.shelfLifeDays
        if exp == nil, let p = prod, let days = shelfLife, days > 0 {
            exp = Calendar.current.date(byAdding: .day, value: days, to: p)
        }
        let needsLearning = sku == nil || conf < 0.6
        let unit = sku?.packagingUnits.first
        return RecognitionResult(
            sku: sku,
            packagingUnit: unit,
            confidence: conf,
            mode: .vision,
            needsLearning: needsLearning,
            recognizedName: raw.skuName,
            recognizedUnit: raw.unitName,
            recognizedCategory: raw.categoryName,
            recognizedShelfLifeDays: shelfLife,
            recognizedBarcode: raw.barcode,
            productionDate: prod,
            expirationDate: exp
        )
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
