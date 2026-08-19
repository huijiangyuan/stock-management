import Foundation
import SwiftData

/// 云端 VLM 视觉识别引擎：拍照 → 调服务商 → 模糊匹配本地 SKU → 预填入库字段。
/// 识别不准（低置信度 / 未命中）一律标记 needsLearning，由 UI 转人工确认，绝不静默错账。
struct CloudVisionEngine: RecognitionEngine {
    let mode: RecognitionMode = .vision

    static let prompt = """
    你是智能库存与商品物料识别助手。请看图识别包装上的商品，并直接返回单行紧凑 JSON（不要多余解释）：
    {
      "sku_name": "准确标准品名，如 可口可乐(330ml) / M8螺栓",
      "unit_name": "基准规格单位，如 箱 / 盒 / 瓶 / 包 / 个 / 罐 / 支 / kg",
      "category_name": "品类，如 食品生鲜 / 酒水饮料 / 日用百货 / 办公耗材 / 五金配件 / 包装耗材 / 机械传动 / 化工辅料 / 电子数码 / 劳保用品",
      "shelf_life_days": 0,
      "barcode": "",
      "production_date": "",
      "expiration_date": "",
      "confidence": 0.95
    }
    注意：品类根据品名准确推算；生产日期/到期日期仅在包装印有清晰真实日期时填写，没有请留空字符串；无保质期或长期有效保质期天数填0，严禁乱填！
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
        let rawDays = (raw.shelfLifeDays != nil && raw.shelfLifeDays! > 0) ? raw.shelfLifeDays : nil
        let shelfLife = rawDays ?? (sku?.shelfLifeDays != nil && sku!.shelfLifeDays > 0 ? sku!.shelfLifeDays : nil)
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

    /// 宽松日期解析：优先 yyyy-MM-dd，兼容 yyyy.MM.dd / yyyy/MM/dd，且年份在合理区间内
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let fmts = ["yyyy-MM-dd", "yyyy.MM.dd", "yyyy/MM/dd"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) {
                let comp = Calendar(identifier: .gregorian).dateComponents([.year], from: d)
                if let y = comp.year, y >= 2015 && y <= 2038 {
                    return d
                }
            }
        }
        return nil
    }
}
