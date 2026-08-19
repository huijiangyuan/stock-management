import Foundation
import SwiftData

// MARK: - 离线数据包 DTO（扁平化外键，便于跨设备恢复）

struct SKUDTO: Codable {
    let skuId, skuCode, skuName, categoryName, baseUnit: String
    let shelfLifeDays: Int
    let createdAt: Date
    let packagingUnits: [PackagingUnitDTO]
    let featureSamples: [FeatureSampleDTO]
}

struct PackagingUnitDTO: Codable {
    let unitId, unitName, unitType: String
    let conversionRatio: Double
    let barcode: String?
}

struct FeatureSampleDTO: Codable {
    let sampleId, angleTag: String
    let unitId: String?
    let ocrTextContent: String?
    let sampleImagePath: String?
    let visionEmbeddingBase64: String?
    let visionModelVersion: String?
    let visionVectorDimension: Int?
    let textEmbeddingBase64: String?
}

struct BatchDTO: Codable {
    let batchId, batchNo, skuCode: String
    let productionDate, expirationDate: Date?
    let supplierName: String?
    let inboundPrice: Double?
}

struct InventoryDTO: Codable {
    let inventoryId, locationName, skuCode: String
    let batchNo: String?
    let qtyBaseUnit: Double
    let updatedAt: Date
}

struct OrderItemDTO: Codable {
    let itemId, skuCode: String
    let unitId: String?
    let batchNo: String?
    let operatingQty, conversionRatio, totalBaseQty: Double
    let recognitionMode: String?
    let confidenceScore: Double?
}

struct OrderDTO: Codable {
    let orderId, orderNo, orderType: String
    let remark: String?
    let createdAt: Date
    let items: [OrderItemDTO]
}

struct ExportPacket: Codable {
    let version: Int
    let exportedAt: Date
    let skus: [SKUDTO]
    let batches: [BatchDTO]
    let inventories: [InventoryDTO]
    let orders: [OrderDTO]
}

/// 离线数据导出/导入（JSON 数据包，可通过 AirDrop / 微信分享）。
/// 导入按唯一 id 幂等合并：已存在则跳过，不存在则插入。
enum ExportImport {
    static func exportAll(context: ModelContext) throws -> ExportPacket {
        let skus = try context.fetch(FetchDescriptor<RawMaterialSKU>())
        let batches = try context.fetch(FetchDescriptor<StockBatch>())
        let inventories = try context.fetch(FetchDescriptor<StockInventory>())
        let orders = try context.fetch(FetchDescriptor<StockOrderHeader>())

        return ExportPacket(
            version: 2,
            exportedAt: Date(),
            skus: skus.map { s in
                SKUDTO(skuId: s.skuId, skuCode: s.skuCode, skuName: s.skuName,
                       categoryName: s.categoryName, baseUnit: s.baseUnit,
                       shelfLifeDays: s.shelfLifeDays, createdAt: s.createdAt,
                       packagingUnits: s.packagingUnits.map {
                           PackagingUnitDTO(unitId: $0.unitId, unitName: $0.unitName,
                                            unitType: $0.unitType,
                                            conversionRatio: $0.conversionRatio, barcode: $0.barcode)
                       },
                       featureSamples: s.featureSamples.map {
                           FeatureSampleDTO(sampleId: $0.sampleId, angleTag: $0.angleTag,
                                            unitId: $0.unit?.unitId,
                                            ocrTextContent: $0.ocrTextContent,
                                            sampleImagePath: $0.sampleImagePath,
                                            visionEmbeddingBase64: $0.visionEmbedding?.base64EncodedString(),
                                            visionModelVersion: $0.visionModelVersion,
                                            visionVectorDimension: $0.visionVectorDimension,
                                            textEmbeddingBase64: $0.textEmbedding?.base64EncodedString())
                       })
            },
            batches: batches.map {
                BatchDTO(batchId: $0.batchId, batchNo: $0.batchNo,
                         skuCode: $0.sku?.skuCode ?? "",
                         productionDate: $0.productionDate, expirationDate: $0.expirationDate,
                         supplierName: $0.supplierName, inboundPrice: $0.inboundPrice)
            },
            inventories: inventories.map {
                InventoryDTO(inventoryId: $0.inventoryId, locationName: $0.locationName,
                             skuCode: $0.sku?.skuCode ?? "",
                             batchNo: $0.batch?.batchNo, qtyBaseUnit: $0.qtyBaseUnit,
                             updatedAt: $0.updatedAt)
            },
            orders: orders.map { o in
                OrderDTO(orderId: o.orderId, orderNo: o.orderNo, orderType: o.orderType,
                         remark: o.remark, createdAt: o.createdAt,
                         items: o.items.map {
                             OrderItemDTO(itemId: $0.itemId, skuCode: $0.sku?.skuCode ?? "",
                                          unitId: $0.unit?.unitId, batchNo: $0.batch?.batchNo,
                                          operatingQty: $0.operatingQty,
                                          conversionRatio: $0.conversionRatio,
                                          totalBaseQty: $0.totalBaseQty,
                                          recognitionMode: $0.recognitionMode,
                                          confidenceScore: $0.confidenceScore)
                         })
            }
        )
    }

    /// 写入 Documents 目录，返回文件 URL（供 UIActivityViewController 分享）
    static func writeToFile(_ packet: ExportPacket) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(packet)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stock_backup_\(Self.stamp()).json")
        try data.write(to: url)
        return url
    }

    /// 将筛选后的单据记录导出为 UTF-8 CSV 报表文件（带 BOM，Excel 打开不乱码）
    static func exportOrdersCSV(orders: [StockOrderHeader], timeRangeTitle: String = "全部") throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateDf = DateFormatter()
        dateDf.dateFormat = "yyyy-MM-dd"

        var csv = "\u{FEFF}" // UTF-8 BOM
        // 表头
        csv += "单据编号,单据类型,操作时间,商品编码,商品名称,商品品类,操作规格,操作数量,换算系数,基准单位,换算基准总量,批次号,生产日期,到期日期,盘前基准数(盘点),实盘基准数(盘点),盘盈盘亏(盘点),识别模式,备注说明\n"

        for order in orders {
            let typeLabel = order.orderType == "INBOUND" ? "入库单" : order.orderType == "OUTBOUND" ? "出库单" : "盘点单"
            let timeStr = df.string(from: order.createdAt)
            let remark = order.remark ?? ""

            for item in order.items {
                let skuCode = item.sku?.skuCode ?? ""
                let skuName = item.sku?.skuName ?? "未知物料"
                let category = item.sku?.categoryName ?? ""
                let unitName = item.unit?.unitName ?? item.sku?.baseUnit ?? "个"
                let opQty = AppFormatters.fmt(item.operatingQty)
                let ratio = AppFormatters.fmt(item.conversionRatio)
                let baseUnit = item.sku?.baseUnit ?? ""
                let totalBase = AppFormatters.fmt(item.totalBaseQty)
                let batchNo = item.batch?.batchNo ?? ""
                let prodDate = item.batch?.productionDate.map { dateDf.string(from: $0) } ?? ""
                let expDate = item.batch?.expirationDate.map { dateDf.string(from: $0) } ?? ""

                var origQtyStr = ""
                var countedQtyStr = ""
                var diffQtyStr = ""
                if order.orderType == "CHECK" {
                    if let orig = item.originalBaseQty { origQtyStr = "\(AppFormatters.fmt(orig))" }
                    countedQtyStr = totalBase
                    if let diff = item.differenceBaseQty {
                        if diff > 0 {
                            diffQtyStr = "盘盈+\(AppFormatters.fmt(diff))"
                        } else if diff < 0 {
                            diffQtyStr = "盘亏\(AppFormatters.fmt(diff))"
                        } else {
                            diffQtyStr = "账实相符"
                        }
                    }
                }

                let mode = item.recognitionMode ?? "MANUAL"
                let note = [item.note, remark].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")

                let row = [
                    order.orderNo,
                    typeLabel,
                    timeStr,
                    skuCode,
                    skuName,
                    category,
                    unitName,
                    opQty,
                    ratio,
                    baseUnit,
                    totalBase,
                    batchNo,
                    prodDate,
                    expDate,
                    origQtyStr,
                    countedQtyStr,
                    diffQtyStr,
                    mode,
                    note
                ].map { escapeCSVField($0) }.joined(separator: ",")

                csv += row + "\n"
            }
        }

        let fileName = "出入库单据报表_\(timeRangeTitle)_\(Self.stamp()).csv"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        guard let data = csv.data(using: .utf8) else {
            throw NSError(domain: "CSVExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法生成 CSV 文本编码"])
        }
        try data.write(to: url)
        return url
    }

    private static func escapeCSVField(_ str: String) -> String {
        if str.contains(",") || str.contains("\"") || str.contains("\n") || str.contains("\r") {
            let replaced = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(replaced)\""
        }
        return str
    }

    static func `import`(from url: URL, context: ModelContext) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let packet = try decoder.decode(ExportPacket.self, from: data)

        let existingSKUIds = Set((try context.fetch(FetchDescriptor<RawMaterialSKU>())).map { $0.skuId })
        let existingBatchIds = Set((try context.fetch(FetchDescriptor<StockBatch>())).map { $0.batchId })
        let existingInvIds = Set((try context.fetch(FetchDescriptor<StockInventory>())).map { $0.inventoryId })
        let existingOrderIds = Set((try context.fetch(FetchDescriptor<StockOrderHeader>())).map { $0.orderId })

        // 1. SKU + 包装 + 特征样本
        for s in packet.skus where !existingSKUIds.contains(s.skuId) {
            let sku = RawMaterialSKU(skuId: s.skuId, skuCode: s.skuCode, skuName: s.skuName,
                                     categoryName: s.categoryName, baseUnit: s.baseUnit,
                                     shelfLifeDays: s.shelfLifeDays)
            sku.createdAt = s.createdAt
            context.insert(sku)
            var importedUnitsByID: [String: PackagingUnit] = [:]
            for u in s.packagingUnits {
                let unit = PackagingUnit(
                    unitId: u.unitId,
                    unitName: u.unitName,
                    unitType: u.unitType,
                    conversionRatio: u.conversionRatio,
                    barcode: u.barcode,
                    sku: sku
                )
                importedUnitsByID[u.unitId] = unit
                context.insert(unit)
            }
            for f in s.featureSamples {
                let sample = FeatureSample(sampleId: f.sampleId, angleTag: f.angleTag,
                                           ocrTextContent: f.ocrTextContent,
                                           sampleImagePath: f.sampleImagePath,
                                           visionEmbedding: f.visionEmbeddingBase64.flatMap { Data(base64Encoded: $0) },
                                           visionModelVersion: f.visionModelVersion ?? "",
                                           visionVectorDimension: f.visionVectorDimension ?? 0,
                                           unit: f.unitId.flatMap { importedUnitsByID[$0] },
                                           sku: sku)
                if let tB64 = f.textEmbeddingBase64 { sample.textEmbedding = Data(base64Encoded: tB64) }
                context.insert(sample)
            }
        }

        // 2. 批次（按 skuCode 关联）
        let skuByCode = try fetchMap(RawMaterialSKU.self, context: context) { $0.skuCode }
        for b in packet.batches where !existingBatchIds.contains(b.batchId) {
            let batch = StockBatch(batchId: b.batchId, batchNo: b.batchNo,
                                   productionDate: b.productionDate, expirationDate: b.expirationDate,
                                   supplierName: b.supplierName, inboundPrice: b.inboundPrice,
                                   sku: skuByCode[b.skuCode])
            context.insert(batch)
        }

        // 3. 库存台账（按 skuCode + batchNo 关联）
        let batchByNo = try fetchMap(StockBatch.self, context: context) { $0.batchNo }
        for inv in packet.inventories where !existingInvIds.contains(inv.inventoryId) {
            let entity = StockInventory(inventoryId: inv.inventoryId, locationName: inv.locationName,
                                        qtyBaseUnit: inv.qtyBaseUnit,
                                        sku: skuByCode[inv.skuCode],
                                        batch: inv.batchNo.flatMap { batchByNo[$0] })
            entity.updatedAt = inv.updatedAt
            context.insert(entity)
        }

        // 4. 单据（按 skuCode / unitId / batchNo 关联）
        let unitById = try fetchMap(PackagingUnit.self, context: context) { $0.unitId }
        for o in packet.orders where !existingOrderIds.contains(o.orderId) {
            let header = StockOrderHeader(orderId: o.orderId, orderNo: o.orderNo,
                                          orderType: o.orderType, remark: o.remark)
            header.createdAt = o.createdAt
            context.insert(header)
            for it in o.items {
                context.insert(StockOrderItem(itemId: it.itemId, operatingQty: it.operatingQty,
                                              conversionRatio: it.conversionRatio,
                                              totalBaseQty: it.totalBaseQty,
                                              recognitionMode: it.recognitionMode,
                                              confidenceScore: it.confidenceScore,
                                              header: header,
                                              sku: skuByCode[it.skuCode],
                                              unit: it.unitId.flatMap { unitById[$0] },
                                              batch: it.batchNo.flatMap { batchByNo[$0] }))
            }
        }
        try context.save()
    }

    // MARK: - 内部辅助
    private static func fetchMap<T: PersistentModel>(_ type: T.Type, context: ModelContext,
                                                     key: (T) -> String) throws -> [String: T] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<T>()).map { (key($0), $0) })
    }

    private static func stamp() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMddHHmmss"; return df.string(from: Date())
    }
}
