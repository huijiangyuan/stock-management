import SwiftUI
import SwiftData

/// 仓库切换与管理抽屉视图：
/// 支持一键快速切换当前仓库、便捷新增仓库、删除仓库二次确认并级联清理库存与单据
struct WarehousePickerSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var warehouseStore = WarehouseStore.shared
    @State private var newWarehouseName = ""
    @State private var warehouseToDelete: String? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false

    var onWarehouseChanged: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                // ── 便捷新增仓库 ─────────────────────────────
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.brand)
                        TextField("输入新仓库名称（如 2号库、冷藏仓）", text: $newWarehouseName)
                            .submitLabel(.done)
                            .onSubmit {
                                handleAdd()
                            }
                        if !newWarehouseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("添加") {
                                handleAdd()
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.brand)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("新增仓库")
                }

                // ── 仓库列表与切换 ───────────────────────────
                Section {
                    ForEach(warehouseStore.warehouses, id: \.self) { name in
                        HStack {
                            Button {
                                warehouseStore.selectWarehouse(name)
                                onWarehouseChanged?()
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: name == warehouseStore.currentWarehouse ? "building.2.crop.circle.fill" : "building.2.crop.circle")
                                        .font(.title3)
                                        .foregroundColor(name == warehouseStore.currentWarehouse ? .brand : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(name)
                                                .font(.body)
                                                .fontWeight(name == warehouseStore.currentWarehouse ? .bold : .regular)
                                                .foregroundColor(.primary)

                                            if name == warehouseStore.currentWarehouse {
                                                Text("当前使用")
                                                    .font(.caption2.bold())
                                                    .foregroundColor(.brand)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.brand.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                        }

                                        let inStockCount = countInStockItems(for: name)
                                        Text("在库物料：\(inStockCount) 种")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if name == warehouseStore.currentWarehouse {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.brand)
                                            .fontWeight(.bold)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            // 删除按钮（支持二次确认）
                            if warehouseStore.warehouses.count > 1 {
                                Button(role: .destructive) {
                                    warehouseToDelete = name
                                    showDeleteConfirm = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(6)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("所有仓库（点击切换）")
                } footer: {
                    Text("提示：删除仓库时将二次确认，并同步清除该仓库名下的所有库存数据与出入库/盘点流水记录。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("仓库管理与切换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("⚠️ 确认删除仓库", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {
                    warehouseToDelete = nil
                }
                Button("确认删除并清空数据", role: .destructive) {
                    if let target = warehouseToDelete {
                        performDelete(target)
                    }
                    warehouseToDelete = nil
                }
            } message: {
                if let target = warehouseToDelete {
                    Text("确定要彻底删除仓库「\(target)」吗？\n\n注意：删除后将【同时清空】该仓库的所有在库库存台账以及关联的历史出入库/盘点单据记录，此操作不可撤销！")
                }
            }
            .alert("删除失败", isPresented: $showDeleteError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage)
            }
        }
    }

    private func handleAdd() {
        let name = newWarehouseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if warehouseStore.addWarehouse(name) {
            newWarehouseName = ""
            onWarehouseChanged?()
            ToastManager.shared.show(message: "🏢 已添加并切换至「\(name)」", tone: .success)
            dismiss()
        }
    }

    private func performDelete(_ name: String) {
        do {
            try warehouseStore.deleteWarehouse(name, context: ctx)
            onWarehouseChanged?()
            ToastManager.shared.show(message: "🗑️ 已删除仓库「\(name)」", details: "关联库存与单据流水已同步清空", tone: .info)
        } catch {
            deleteErrorMessage = "删除仓库失败：\(error.localizedDescription)"
            showDeleteError = true
        }
    }

    private func countInStockItems(for warehouse: String) -> Int {
        let descriptor = FetchDescriptor<StockInventory>(predicate: #Predicate { $0.qtyBaseUnit > 0 })
        guard let invs = try? ctx.fetch(descriptor) else { return 0 }
        let matching = invs.filter { $0.locationName == warehouse }
        return Set(matching.compactMap { $0.sku?.skuId }).count
    }
}
