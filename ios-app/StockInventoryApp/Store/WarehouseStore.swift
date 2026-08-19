import Foundation
import SwiftData
import SwiftUI

/// 仓库多仓管理中心：负责仓库列表维护、当前仓库切换、便捷添加与二次确认级联删除
@Observable
final class WarehouseStore {
    static let shared = WarehouseStore()

    private let warehousesKey = "StockManager_Warehouses_List"
    private let currentWarehouseKey = "StockManager_Current_Warehouse"

    var warehouses: [String] = ["默认仓库"]
    var currentWarehouse: String = "默认仓库"

    init() {
        load()
    }

    func load() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: warehousesKey), !saved.isEmpty {
            warehouses = saved
        } else {
            warehouses = ["默认仓库"]
            defaults.set(warehouses, forKey: warehousesKey)
        }

        if let curr = defaults.string(forKey: currentWarehouseKey), warehouses.contains(curr) {
            currentWarehouse = curr
        } else {
            currentWarehouse = warehouses.first ?? "默认仓库"
            defaults.set(currentWarehouse, forKey: currentWarehouseKey)
        }
    }

    /// 切换当前活动仓库
    func selectWarehouse(_ name: String) {
        guard warehouses.contains(name) else { return }
        currentWarehouse = name
        UserDefaults.standard.set(name, forKey: currentWarehouseKey)
    }

    /// 添加新仓库（自动去重并选中）
    @discardableResult
    func addWarehouse(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if !warehouses.contains(trimmed) {
            warehouses.append(trimmed)
            UserDefaults.standard.set(warehouses, forKey: warehousesKey)
        }
        selectWarehouse(trimmed)
        return true
    }

    /// 删除指定仓库及其关联的所有库存与单据
    func deleteWarehouse(_ name: String, context: ModelContext) throws {
        // 1. 级联删除数据
        let store = InventoryStore(context: context)
        try store.deleteWarehouse(name: name)

        // 2. 更新仓库列表
        warehouses.removeAll { $0 == name }
        if warehouses.isEmpty {
            warehouses = ["默认仓库"]
        }
        UserDefaults.standard.set(warehouses, forKey: warehousesKey)

        // 3. 若删除的是当前仓库，切换到剩余的首个仓库
        if currentWarehouse == name {
            currentWarehouse = warehouses.first ?? "默认仓库"
            UserDefaults.standard.set(currentWarehouse, forKey: currentWarehouseKey)
        }
    }
}
