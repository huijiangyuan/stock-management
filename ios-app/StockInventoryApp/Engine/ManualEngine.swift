import Foundation
import SwiftData

/// 手动识别引擎：按 SKU 编码精确匹配；未命中则进入学习模式（建库/确认）。
struct ManualEngine: RecognitionEngine {
    let mode: RecognitionMode = .manual

    func recognize(_ input: RecognitionInput, context: ModelContext) -> RecognitionResult {
        if let code = input.manualSkuCode, !code.isEmpty {
            let descriptor = FetchDescriptor<RawMaterialSKU>(
                predicate: #Predicate { $0.skuCode == code }
            )
            if let sku = try? context.fetch(descriptor).first {
                return RecognitionResult(sku: sku, packagingUnit: nil, confidence: 1.0,
                                         mode: .manual, needsLearning: false)
            }
        }
        return RecognitionResult(sku: nil, packagingUnit: nil, confidence: 0,
                                 mode: .manual, needsLearning: true)
    }
}
