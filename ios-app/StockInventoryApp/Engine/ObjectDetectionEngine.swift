//
//  ObjectDetectionEngine.swift
//  StockInventoryApp · 目标物检测与智能 ROI 裁剪
//

import CoreGraphics
import Foundation
import ImageIO
import UIKit
import Vision

/// 检测到的目标物感兴趣区域（ROI）
struct DetectedObjectROI: Sendable, Equatable {
    /// 归一化矩形坐标（以左上角为原点，取值范围 0.0 ~ 1.0）
    let normalizedRect: CGRect
    /// 置信度 (0.0 ~ 1.0)
    let confidence: Float
    /// 检测来源（如显著性物体、注意力焦点、几何矩形）
    let source: String

    var isValid: Bool {
        normalizedRect.width > 0.05 && normalizedRect.height > 0.05 &&
        normalizedRect.width <= 1.0 && normalizedRect.height <= 1.0
    }
}

/// 目标物检测接口协议（支持未来无缝扩展 YOLO 等第三方模型）
protocol ObjectDetectorProviding: Sendable {
    /// 从 CGImage 中检测最显著的目标物体边界框
    func detectTargetObject(in cgImage: CGImage) async throws -> DetectedObjectROI?
    
    /// 从 CVPixelBuffer（如相机视频帧）中极速检测目标物体
    func detectTargetObject(in pixelBuffer: CVPixelBuffer) async throws -> DetectedObjectROI?
}

/// 基于 Apple Vision 深度显著性（Objectness & Attention Saliency）与几何矩形融合的目标检测引擎。
/// 零额外模型文件，运行在 Apple Neural Engine / Metal 硬件加速器，单次推断耗时 5~15ms，零额外常驻内存。
final class ObjectDetectionEngine: ObjectDetectorProviding {
    static let shared = ObjectDetectionEngine()

    /// 最小目标占比（若检测目标小于画面的 3%，可能为细小噪点）
    private let minimumAreaRatio: CGFloat = 0.03
    /// 最大目标占比（若大于 92%，说明物体基本占满全屏，无需激进裁剪）
    private let maximumAreaRatio: CGFloat = 0.92

    init() {}

    /// 检测图像中的目标物归一化边界框（UIKit 坐标系：左上角 (0,0)）
    func detectTargetObject(in cgImage: CGImage) async throws -> DetectedObjectROI? {
        try await withCheckedThrowingContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            performDetection(handler: requestHandler, continuation: continuation)
        }
    }

    /// 从相机实时视频帧中极速检测目标物
    func detectTargetObject(in pixelBuffer: CVPixelBuffer) async throws -> DetectedObjectROI? {
        try await withCheckedThrowingContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            performDetection(handler: requestHandler, continuation: continuation)
        }
    }

    private func performDetection(
        handler: VNImageRequestHandler,
        continuation: CheckedContinuation<DetectedObjectROI?, any Error>
    ) {
        // 1. 规则几何轮廓与矩形物料检测（包装盒、物料箱、托盘、商品包装、标牌）
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumConfidence = 0.55
        rectangleRequest.minimumAspectRatio = 0.15
        rectangleRequest.maximumAspectRatio = 4.0
        rectangleRequest.minimumSize = 0.12 // 至少占画面 12%
        rectangleRequest.maximumObservations = 5

        // 2. 基于前景物料显著性分析（Objectness Saliency，针对袋装物、零件等不规则物理实体）
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        // 3. 基于视觉注意力焦点分析（Attention Saliency，中心焦点兜底）
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        do {
            try handler.perform([rectangleRequest, objectnessRequest, attentionRequest])

            var bestROI: DetectedObjectROI?

            // 优先策略 1：检查是否有明确的矩形包装/物料轮廓
            if let rectangles = rectangleRequest.results, !rectangles.isEmpty {
                // 筛选靠近中央、面积合理的矩形轮廓
                let candidates = rectangles.compactMap { rect -> (CGRect, Float)? in
                    let uikitRect = Self.convertVisionRectToUIKit(rect.boundingBox)
                    let area = uikitRect.width * uikitRect.height
                    guard area >= minimumAreaRatio && area <= maximumAreaRatio else { return nil }
                    return (uikitRect, rect.confidence)
                }

                if let bestRect = candidates.min(by: {
                    let center0 = CGPoint(x: $0.0.midX, y: $0.0.midY)
                    let center1 = CGPoint(x: $1.0.midX, y: $1.0.midY)
                    let dist0 = hypot(center0.x - 0.5, center0.y - 0.5)
                    let dist1 = hypot(center1.x - 0.5, center1.y - 0.5)
                    return dist0 < dist1
                }) {
                    bestROI = DetectedObjectROI(
                        normalizedRect: bestRect.0,
                        confidence: bestRect.1,
                        source: "rectangle_contour"
                    )
                }
            }

            // 优先策略 2：若无明显规则矩形，采用 Objectness Saliency 提取的前景实体
            if bestROI == nil,
               let objectnessResult = objectnessRequest.results?.first,
               let salientObjects = objectnessResult.salientObjects,
               !salientObjects.isEmpty {
                if let bestObject = salientObjects.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                    let convertedRect = Self.convertVisionRectToUIKit(bestObject.boundingBox)
                    let area = convertedRect.width * convertedRect.height
                    if area >= minimumAreaRatio && area <= maximumAreaRatio {
                        bestROI = DetectedObjectROI(
                            normalizedRect: convertedRect,
                            confidence: bestObject.confidence,
                            source: "objectness_saliency"
                        )
                    }
                }
            }

            // 优先策略 3：视觉注意力焦点重心提取兜底
            if bestROI == nil,
               let attentionResult = attentionRequest.results?.first,
               let salientObjects = attentionResult.salientObjects,
               !salientObjects.isEmpty {
                if let bestAttention = salientObjects.first {
                    let convertedRect = Self.convertVisionRectToUIKit(bestAttention.boundingBox)
                    let area = convertedRect.width * convertedRect.height
                    if area >= minimumAreaRatio && area <= maximumAreaRatio {
                        bestROI = DetectedObjectROI(
                            normalizedRect: convertedRect,
                            confidence: bestAttention.confidence,
                            source: "attention_saliency"
                        )
                    }
                }
            }

            continuation.resume(returning: bestROI)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    /// 智能安全裁剪：将原图按照目标 ROI 裁剪，外加安全边距（Padding），并保证尺寸和格式安全
    static func crop(
        image: UIImage,
        to normalizedRect: CGRect,
        paddingFraction: CGFloat = 0.08,
        compressionQuality: CGFloat = 0.85
    ) -> ProcessedCapturedImage? {
        guard let cgImage = image.cgImage else { return nil }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // 1. 扩展安全边距（避免切除边缘字样或外包装轮廓）
        let expanded = expand(normalizedRect: normalizedRect, paddingFraction: paddingFraction)

        // 2. 映射为绝对像素坐标
        let pixelCropRect = CGRect(
            x: expanded.origin.x * imageWidth,
            y: expanded.origin.y * imageHeight,
            width: expanded.size.width * imageWidth,
            height: expanded.size.height * imageHeight
        ).integral

        // 边界保护检查
        guard pixelCropRect.width > 20,
              pixelCropRect.height > 20,
              pixelCropRect.origin.x >= 0,
              pixelCropRect.origin.y >= 0,
              pixelCropRect.maxX <= imageWidth + 1,
              pixelCropRect.maxY <= imageHeight + 1 else {
            return nil
        }

        // 3. 执行 CGImage 裁剪
        guard let croppedCGImage = cgImage.cropping(to: pixelCropRect) else {
            return nil
        }

        let croppedUIImage = UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
        guard let jpegData = croppedUIImage.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }

        return ProcessedCapturedImage(
            jpegData: jpegData,
            pixelWidth: croppedCGImage.width,
            pixelHeight: croppedCGImage.height
        )
    }

    /// 智能安全裁剪（从 JPEG Data 裁剪）
    static func crop(
        imageData: Data,
        to normalizedRect: CGRect,
        paddingFraction: CGFloat = 0.08,
        compressionQuality: CGFloat = 0.85
    ) -> ProcessedCapturedImage? {
        guard let image = UIImage(data: imageData) else { return nil }
        return crop(image: image, to: normalizedRect, paddingFraction: paddingFraction, compressionQuality: compressionQuality)
    }

    /// 将 Vision 坐标系（左下角为原点）转换为 UIKit 坐标系（左上角为原点）
    static func convertVisionRectToUIKit(_ visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.origin.x,
            y: 1.0 - visionRect.origin.y - visionRect.size.height,
            width: visionRect.size.width,
            height: visionRect.size.height
        )
    }

    /// 向外安全扩展 Bounding Box（并严格限制在 [0, 1] 坐标系内）
    static func expand(normalizedRect: CGRect, paddingFraction: CGFloat) -> CGRect {
        let dx = normalizedRect.width * paddingFraction
        let dy = normalizedRect.height * paddingFraction

        let newX = max(0.0, normalizedRect.origin.x - dx)
        let newY = max(0.0, normalizedRect.origin.y - dy)
        let newMaxX = min(1.0, normalizedRect.maxX + dx)
        let newMaxY = min(1.0, normalizedRect.maxY + dy)

        return CGRect(
            x: newX,
            y: newY,
            width: max(0.0, newMaxX - newX),
            height: max(0.0, newMaxY - newY)
        )
    }
}
