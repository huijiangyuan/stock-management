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

    /// 视频流时间序列追踪与坐标平滑器（防止多物体跳变横跳与微颤）
    private let videoTracker = TemporalObjectTracker()

    /// 检测图像中的目标物归一化边界框（静态图识别）
    func detectTargetObject(in cgImage: CGImage) async throws -> DetectedObjectROI? {
        try await withCheckedThrowingContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                let candidates = try extractCandidates(handler: requestHandler)
                let best = TemporalObjectTracker.selectBestCandidate(from: candidates, preferredPoint: nil)
                continuation.resume(returning: best)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 从相机实时视频帧中极速检测目标物（带时间序列连续性锁定与 EMA 坐标平滑）
    func detectTargetObject(in pixelBuffer: CVPixelBuffer) async throws -> DetectedObjectROI? {
        try await withCheckedThrowingContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                let candidates = try extractCandidates(handler: requestHandler)
                let tracked = videoTracker.process(candidates: candidates, timestamp: CACurrentMediaTime())
                continuation.resume(returning: tracked)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 重置视频流跟踪器状态
    func resetTracker() {
        videoTracker.reset()
    }

    /// 优先锁定指定归一化坐标附近的目标（例如用户手动点击对焦处）
    func prioritizeTarget(near point: CGPoint) {
        videoTracker.prioritize(point: point)
    }

    /// 从单帧图像中提取所有合格的候选物理实体（矩形轮廓、显著性前景、视觉重心）
    private func extractCandidates(handler: VNImageRequestHandler) throws -> [DetectedObjectROI] {
        // 1. 规则几何轮廓与矩形物料检测（包装盒、物料箱、托盘、商品包装、标牌）
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumConfidence = 0.55
        rectangleRequest.minimumAspectRatio = 0.15
        rectangleRequest.maximumAspectRatio = 4.0
        rectangleRequest.minimumSize = 0.10
        rectangleRequest.maximumObservations = 6

        // 2. 基于前景物料显著性分析（Objectness Saliency，针对袋装物、零件等不规则物理实体）
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        // 3. 基于视觉注意力焦点分析（Attention Saliency，中心焦点兜底）
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        try handler.perform([rectangleRequest, objectnessRequest, attentionRequest])

        var candidates: [DetectedObjectROI] = []

        // 提取矩形轮廓候选
        if let rectangles = rectangleRequest.results {
            for rect in rectangles {
                let uikitRect = Self.convertVisionRectToUIKit(rect.boundingBox)
                let area = uikitRect.width * uikitRect.height
                if area >= minimumAreaRatio && area <= maximumAreaRatio {
                    candidates.append(
                        DetectedObjectROI(
                            normalizedRect: uikitRect,
                            confidence: rect.confidence,
                            source: "rectangle_contour"
                        )
                    )
                }
            }
        }

        // 提取前景实体候选
        if let objectnessResult = objectnessRequest.results?.first,
           let salientObjects = objectnessResult.salientObjects {
            for obj in salientObjects {
                let uikitRect = Self.convertVisionRectToUIKit(obj.boundingBox)
                let area = uikitRect.width * uikitRect.height
                if area >= minimumAreaRatio && area <= maximumAreaRatio {
                    // 若与已有的矩形候选高度重合，避免重复添加
                    let isDuplicate = candidates.contains { existing in
                        TemporalObjectTracker.calculateIoU(rectA: existing.normalizedRect, rectB: uikitRect) > 0.65
                    }
                    if !isDuplicate {
                        candidates.append(
                            DetectedObjectROI(
                                normalizedRect: uikitRect,
                                confidence: obj.confidence,
                                source: "objectness_saliency"
                            )
                        )
                    }
                }
            }
        }

        // 视觉注意力焦点兜底
        if candidates.isEmpty,
           let attentionResult = attentionRequest.results?.first,
           let salientObjects = attentionResult.salientObjects,
           let bestAttention = salientObjects.first {
            let uikitRect = Self.convertVisionRectToUIKit(bestAttention.boundingBox)
            let area = uikitRect.width * uikitRect.height
            if area >= minimumAreaRatio && area <= maximumAreaRatio {
                candidates.append(
                    DetectedObjectROI(
                        normalizedRect: uikitRect,
                        confidence: bestAttention.confidence,
                        source: "attention_saliency"
                    )
                )
            }
        }

        return candidates
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

/// 目标跟踪与平滑稳定器：解决多物体场景下的频繁跳变（Flipping）、框抖动与忽大忽小问题
final class TemporalObjectTracker: @unchecked Sendable {
    private var lockedTarget: DetectedObjectROI?
    private var smoothedRect: CGRect?
    private var lastSeenTimestamp: TimeInterval = 0
    private var framesWithoutLockedTarget: Int = 0
    private var userPrioritizedPoint: CGPoint?
    private var userPriorityExpiry: TimeInterval = 0

    /// EMA 坐标平滑系数（0.38：兼顾快速跟随位移与滤除噪点抖动）
    private let smoothingAlpha: CGFloat = 0.38
    /// 最小位移死区（低于此变动视为静止，防止像素级微颤）
    private let deadzoneThreshold: CGFloat = 0.0035

    /// 处理新一帧检测到的所有候选目标，输出经过时间锁定与平滑滤波后的稳定主目标
    func process(candidates: [DetectedObjectROI], timestamp: TimeInterval) -> DetectedObjectROI? {
        guard !candidates.isEmpty else {
            framesWithoutLockedTarget += 1
            if timestamp - lastSeenTimestamp > 0.45 {
                reset()
                return nil
            }
            return lockedTarget
        }

        // 检查用户是否有手动点击对焦的优先锚点（优先持续 2.0 秒）
        var targetPoint: CGPoint?
        if let pt = userPrioritizedPoint, timestamp < userPriorityExpiry {
            targetPoint = pt
        } else {
            userPrioritizedPoint = nil
        }

        // 1. 如果已有锁定目标，优先在候选集中寻找同一个物体（连续性优先，防止多物体频繁横跳）
        if let current = lockedTarget, let previousRect = smoothedRect, targetPoint == nil {
            var bestMatch: DetectedObjectROI?
            var bestScore: CGFloat = -1

            for candidate in candidates {
                let iou = Self.calculateIoU(rectA: candidate.normalizedRect, rectB: previousRect)
                let dist = hypot(candidate.normalizedRect.midX - previousRect.midX, candidate.normalizedRect.midY - previousRect.midY)

                // 判定为同一物体的条件：IoU >= 0.18 或中心位移极小 (< 0.22)
                if iou >= 0.18 || dist < 0.22 {
                    let matchScore = iou * 2.5 + max(0.0, 1.0 - dist)
                    if matchScore > bestScore {
                        bestScore = matchScore
                        bestMatch = candidate
                    }
                }
            }

            if let matched = bestMatch {
                // 成功追踪到同一物体！
                framesWithoutLockedTarget = 0
                lastSeenTimestamp = timestamp

                // EMA 平滑滤波
                let newSmoothed = applyEMA(current: previousRect, target: matched.normalizedRect)
                smoothedRect = newSmoothed

                let updatedTarget = DetectedObjectROI(
                    normalizedRect: newSmoothed,
                    confidence: matched.confidence,
                    source: matched.source
                )
                lockedTarget = updatedTarget
                return updatedTarget
            } else {
                framesWithoutLockedTarget += 1
                // 连续 4 帧以上丢失才允许切换到新目标，避免单帧遮挡或跳变
                if framesWithoutLockedTarget < 4, timestamp - lastSeenTimestamp < 0.35 {
                    return lockedTarget
                }
            }
        }

        // 2. 选择新的主目标：以画面中心（或用户点击点）距离权重为主，抑制边缘物体抢焦
        guard let winner = Self.selectBestCandidate(from: candidates, preferredPoint: targetPoint) else {
            return nil
        }

        // 锁定新目标并初始化平滑器
        lockedTarget = winner
        smoothedRect = winner.normalizedRect
        lastSeenTimestamp = timestamp
        framesWithoutLockedTarget = 0
        return winner
    }

    /// 用户手动点击对焦时，优先锁定点击位置附近的物体
    func prioritize(point: CGPoint) {
        userPrioritizedPoint = point
        userPriorityExpiry = CACurrentMediaTime() + 2.5
        // 清理当前锁定，立即在下一帧吸附到点击点附近的物体
        lockedTarget = nil
        smoothedRect = nil
    }

    /// 重置跟踪器状态
    func reset() {
        lockedTarget = nil
        smoothedRect = nil
        framesWithoutLockedTarget = 0
        userPrioritizedPoint = nil
    }

    /// 从候选集合中筛选最佳主目标
    static func selectBestCandidate(from candidates: [DetectedObjectROI], preferredPoint: CGPoint?) -> DetectedObjectROI? {
        let anchor = preferredPoint ?? CGPoint(x: 0.5, y: 0.5)

        let scored = candidates.map { candidate -> (DetectedObjectROI, CGFloat) in
            let rect = candidate.normalizedRect
            let dist = hypot(rect.midX - anchor.x, rect.midY - anchor.y)
            let proximityScore = max(0.0, 1.0 - (dist / 0.707))

            // 面积适中度得分：0.15~0.60 最佳
            let area = rect.width * rect.height
            let areaScore = 1.0 - min(abs(area - 0.35) / 0.35, 1.0)

            // 规整矩形检测源（有明确物理包装盒边缘）稳定性奖励
            let sourceBonus: CGFloat = (candidate.source == "rectangle_contour") ? 0.25 : 0.0

            let totalScore = proximityScore * 0.55 + CGFloat(candidate.confidence) * 0.20 + areaScore * 0.15 + sourceBonus
            return (candidate, totalScore)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    /// EMA 指数移动平均平滑滤波与死区微颤抑制
    private func applyEMA(current: CGRect, target: CGRect) -> CGRect {
        var dx = target.origin.x - current.origin.x
        var dy = target.origin.y - current.origin.y
        var dw = target.size.width - current.size.width
        var dh = target.size.height - current.size.height

        // 最小死区微颤过滤：位移变动低于阈值视为静止
        if abs(dx) < deadzoneThreshold { dx = 0 }
        if abs(dy) < deadzoneThreshold { dy = 0 }
        if abs(dw) < deadzoneThreshold { dw = 0 }
        if abs(dh) < deadzoneThreshold { dh = 0 }

        let newX = current.origin.x + dx * smoothingAlpha
        let newY = current.origin.y + dy * smoothingAlpha
        let newW = current.size.width + dw * smoothingAlpha
        let newH = current.size.height + dh * smoothingAlpha

        return CGRect(
            x: max(0.0, min(1.0 - newW, newX)),
            y: max(0.0, min(1.0 - newH, newY)),
            width: max(0.05, min(1.0, newW)),
            height: max(0.05, min(1.0, newH))
        )
    }

    /// 计算两矩形交并比（IoU）
    static func calculateIoU(rectA: CGRect, rectB: CGRect) -> CGFloat {
        let intersection = rectA.intersection(rectB)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (rectA.width * rectA.height) + (rectB.width * rectB.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}
