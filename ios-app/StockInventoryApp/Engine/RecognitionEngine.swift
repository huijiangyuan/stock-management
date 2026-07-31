import Foundation
import SwiftData

/// 识别来源模式
enum RecognitionMode: String, Codable {
    case barcode = "BARCODE"
    case manual = "MANUAL"
}

/// 识别输入（不同引擎取不同字段）
struct RecognitionInput {
    var barcode: String?
    var manualSkuCode: String?
}

/// 识别结果（纯本地解析，无云端调用）
struct RecognitionResult {
    var sku: RawMaterialSKU?
    var packagingUnit: PackagingUnit?
    var confidence: Double
    var mode: RecognitionMode
    var needsLearning: Bool      // true 表示本地未命中，需员工建库/确认
}

/// 可插拔识别引擎协议。后续可新增 OnDeviceVLMEngine / EmbeddingEngine 实现，业务层无感知。
protocol RecognitionEngine {
    var mode: RecognitionMode { get }
    func recognize(_ input: RecognitionInput, context: ModelContext) -> RecognitionResult
}
