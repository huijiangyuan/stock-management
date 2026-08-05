import Foundation
import SwiftData

/// 多模态特征样本表（学习模式：拍照/文本注册）。对应 DDL: material_feature_sample
/// 注：visionEmbedding / textEmbedding 预留为 Float32 的 Data，sqlite-vec 向量检索为后续可插拔扩展点。
@Model
final class FeatureSample {
    @Attribute(.unique) var sampleId: String
    var angleTag: String            // FRONT / SIDE / MARK
    var ocrTextContent: String?
    var sampleImagePath: String?    // 本地图片存储路径
    var visionEmbedding: Data?      // Float32 图片向量
    var visionModelVersion: String = ""
    var visionVectorDimension: Int = 0
    var textEmbedding: Data?        // 384 维 Float32（占位）
    var createdAt: Date

    var unit: PackagingUnit?
    var sku: RawMaterialSKU?

    init(sampleId: String = UUID().uuidString,
         angleTag: String = "FRONT",
         ocrTextContent: String? = nil,
         sampleImagePath: String? = nil,
         visionEmbedding: Data? = nil,
         visionModelVersion: String = "",
         visionVectorDimension: Int = 0,
         unit: PackagingUnit? = nil,
         sku: RawMaterialSKU? = nil) {
        self.sampleId = sampleId
        self.angleTag = angleTag
        self.ocrTextContent = ocrTextContent
        self.sampleImagePath = sampleImagePath
        self.visionEmbedding = visionEmbedding
        self.visionModelVersion = visionModelVersion
        self.visionVectorDimension = visionVectorDimension
        self.unit = unit
        self.sku = sku
        self.createdAt = Date()
    }
}
