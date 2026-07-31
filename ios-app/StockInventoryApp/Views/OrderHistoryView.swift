import SwiftUI
import SwiftData

struct OrderHistoryView: View {
    @Query(sort: \StockOrderHeader.createdAt, order: .reverse) private var orders: [StockOrderHeader]

    var body: some View {
        NavigationStack {
            Group {
                if orders.isEmpty {
                    EmptyState(title: "暂无单据", hint: "在首页或库存详情中创建入库 / 出库 / 盘点单")
                } else {
                    List {
                        ForEach(orders) { o in
                            Section {
                                ForEach(o.items) { it in
                                    HStack {
                                        Text(it.sku?.skuName ?? "未知商品")
                                        if let u = it.unit {
                                            Text("· \(u.unitName)").foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text("\(AppFormatters.fmt(it.totalBaseQty)) \(it.sku?.baseUnit ?? "")")
                                            .font(.subheadline).bold()
                                    }
                                    .font(.subheadline)
                                }
                                if let remark = o.remark, !remark.isEmpty {
                                    Text("备注：\(remark)").font(.caption).foregroundColor(.secondary)
                                }
                            } header: {
                                HStack {
                                    Text(o.orderNo)
                                    Spacer()
                                    Text(typeLabel(o.orderType))
                                        .foregroundColor(typeColor(o.orderType))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("单据历史")
        }
    }

    private func typeLabel(_ t: String) -> String {
        t == "INBOUND" ? "入库" : t == "OUTBOUND" ? "出库" : "盘点"
    }

    private func typeColor(_ t: String) -> Color {
        t == "INBOUND" ? .success : t == "OUTBOUND" ? .brand : .warning
    }
}
