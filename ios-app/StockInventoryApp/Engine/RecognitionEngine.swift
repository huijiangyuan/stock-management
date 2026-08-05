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

/// 识别结果。视觉识别会带回 recognizedName / 生产日期 / 到期日，供入库单预填。
struct RecognitionResult {
    var sku: RawMaterialSKU?
    var packagingUnit: PackagingUnit?
    var confidence: Double
    var mode: RecognitionMode
    var needsLearning: Bool
    var recognizedName: String?
    var productionDate: Date?
    var expirationDate: Date?

    init(sku: RawMaterialSKU? = nil,
         packagingUnit: PackagingUnit? = nil,
         confidence: Double,
         mode: RecognitionMode,
         needsLearning: Bool,
         recognizedName: String? = nil,
         productionDate: Date? = nil,
         expirationDate: Date? = nil) {
        self.sku = sku
        self.packagingUnit = packagingUnit
        self.confidence = confidence
        self.mode = mode
        self.needsLearning = needsLearning
        self.recognizedName = recognizedName
        self.productionDate = productionDate
        self.expirationDate = expirationDate
    }
}

enum VisionRecognitionSource: String, Sendable {
    case vector = "本地图片向量"
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
