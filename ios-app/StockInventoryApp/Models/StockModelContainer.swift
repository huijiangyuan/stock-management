import Foundation
import SwiftData

/// 统一本地数据库容器（SwiftData 底层即 SQLite，完全离线、无后端）。
enum StockModelContainer {
    static let schema = Schema([
        RawMaterialSKU.self,
        PackagingUnit.self,
        FeatureSample.self,
        StockBatch.self,
        StockInventory.self,
        StockOrderHeader.self,
        StockOrderItem.self
    ])

    static let configuration = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: false,
        allowsSave: true
    )

    static func create() -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法创建本地数据库容器: \(error)")
        }
    }
}
