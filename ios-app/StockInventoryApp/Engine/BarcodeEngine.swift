import Foundation
import SwiftData

/// 条码识别引擎：通过包装条码（AVFoundation 扫码得到）反查 SKU 与规格。
/// 条码与包装规格绑定（schema: sku_packaging_unit.barcode）。
struct BarcodeEngine: RecognitionEngine {
    let mode: RecognitionMode = .barcode

    func recognize(_ input: RecognitionInput, context: ModelContext) async -> RecognitionResult {
        guard let barcode = input.barcode, !barcode.isEmpty else {
            return RecognitionResult(sku: nil, packagingUnit: nil, confidence: 0,
                                     mode: .barcode, needsLearning: true)
        }
        let descriptor = FetchDescriptor<PackagingUnit>(
            predicate: #Predicate { $0.barcode == barcode }
        )
        guard let unit = try? context.fetch(descriptor).first, let sku = unit.sku else {
            return RecognitionResult(sku: nil, packagingUnit: nil, confidence: 0,
                                     mode: .barcode, needsLearning: true)
        }
        return RecognitionResult(sku: sku, packagingUnit: unit, confidence: 1.0,
                                 mode: .barcode, needsLearning: false)
    }
}
