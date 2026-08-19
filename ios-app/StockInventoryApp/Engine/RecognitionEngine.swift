import Foundation
import SwiftData

/// 识别来源模式
enum RecognitionMode: String, Codable {
    case barcode = "BARCODE"
    case manual = "MANUAL"
    case vision = "VISION"
}

/// 识别输入（不同引擎取不同字段）
struct RecognitionInput {
    var barcode: String?
    var manualSkuCode: String?
    var visionImage: Data?   // 摄像头拍照 JPEG
}

/// 识别结果。视觉识别会带回品名、单位、品类、保质期天数、生产日期与到期日，供商品建档与入库单自动完整填表。
struct RecognitionResult {
    var sku: RawMaterialSKU?
    var packagingUnit: PackagingUnit?
    var confidence: Double
    var mode: RecognitionMode
    var needsLearning: Bool
    var recognizedName: String?
    var recognizedUnit: String?
    var recognizedCategory: String?
    var recognizedShelfLifeDays: Int?
    var recognizedBarcode: String?
    var recognizedPackagingSpec: String?       // 如“箱(×24)”
    var recognizedConversionRatio: Double?     // 换算系数，如 24.0
    var productionDate: Date?
    var expirationDate: Date?

    init(sku: RawMaterialSKU? = nil,
         packagingUnit: PackagingUnit? = nil,
         confidence: Double,
         mode: RecognitionMode,
         needsLearning: Bool,
         recognizedName: String? = nil,
         recognizedUnit: String? = nil,
         recognizedCategory: String? = nil,
         recognizedShelfLifeDays: Int? = nil,
         recognizedBarcode: String? = nil,
         recognizedPackagingSpec: String? = nil,
         recognizedConversionRatio: Double? = nil,
         productionDate: Date? = nil,
         expirationDate: Date? = nil) {
        self.sku = sku
        self.packagingUnit = packagingUnit
        self.confidence = confidence
        self.mode = mode
        self.needsLearning = needsLearning
        self.recognizedName = recognizedName
        self.recognizedUnit = recognizedUnit
        self.recognizedCategory = recognizedCategory
        self.recognizedShelfLifeDays = recognizedShelfLifeDays
        self.recognizedBarcode = recognizedBarcode
        self.recognizedPackagingSpec = recognizedPackagingSpec
        self.recognizedConversionRatio = recognizedConversionRatio
        self.productionDate = productionDate
        self.expirationDate = expirationDate
    }

    /// 显示或建库使用的有效单位名称
    var displayUnitName: String? {
        packagingUnit?.unitName ?? recognizedUnit
    }

    /// 显示或建库使用的有效品类名称
    var displayCategoryName: String? {
        sku?.categoryName ?? recognizedCategory
    }

    /// 显示或建库使用的有效保质期天数
    var displayShelfLifeDays: Int? {
        if let days = sku?.shelfLifeDays, days > 0 { return days }
        if let days = recognizedShelfLifeDays, days > 0 { return days }
        if let p = productionDate, let e = expirationDate {
            let diff = Calendar.current.dateComponents([.day], from: p, to: e).day ?? 0
            if diff > 0 { return diff }
        }
        return nil
    }
}

/// 新品登记建档预填草稿数据包
struct SKUPrefillDraft: Sendable {
    var skuName: String
    var categoryName: String
    var baseUnit: String
    var shelfLifeDays: Int
    var barcode: String?
    var packagingUnitName: String?
    var conversionRatio: Double?
    var productionDate: Date?
    var expirationDate: Date?
    var visionOutcome: VisionRecognitionOutcome?
}

enum VisionRecognitionSource: String, Sendable {
    case vector = "本地图片向量"
    case ocr = "端侧极速识字"
    case miniCPM = "端侧 MiniCPM-V"
    case cloud = "云端 VLM"
    case unavailable = "未识别"
}

struct VisionRecognitionOutcome {
    let recognitionID: String
    let result: RecognitionResult
    let processedImage: ProcessedCapturedImage
    let embedding: ImageEmbedding?
    let matches: [FeatureMatch]
    let source: VisionRecognitionSource
}

/// 可插拔识别引擎协议。条码 / 手动 / 视觉（云端 VLM）统一走 recognize。
/// 视觉识别必须异步（网络调用），故协议方法为 async。
protocol RecognitionEngine {
    var mode: RecognitionMode { get }
    func recognize(_ input: RecognitionInput, context: ModelContext) async -> RecognitionResult
}
