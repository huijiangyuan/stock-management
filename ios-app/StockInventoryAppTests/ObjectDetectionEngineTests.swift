//
//  ObjectDetectionEngineTests.swift
//  StockInventoryAppTests · 目标物检测与 ROI 裁剪测试
//

import CoreGraphics
import UIKit
import XCTest
@testable import StockInventoryApp

final class ObjectDetectionEngineTests: XCTestCase {

    func testExpandNormalizedRectWithinBounds() {
        let original = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let expanded = ObjectDetectionEngine.expand(normalizedRect: original, paddingFraction: 0.1)

        // 预期宽高各扩展 10%
        XCTAssertEqual(expanded.origin.x, 0.16, accuracy: 0.001)
        XCTAssertEqual(expanded.origin.y, 0.16, accuracy: 0.001)
        XCTAssertEqual(expanded.width, 0.48, accuracy: 0.001)
        XCTAssertEqual(expanded.height, 0.48, accuracy: 0.001)
    }

    func testExpandNormalizedRectClampedToZeroOne() {
        let edgeRect = CGRect(x: 0.02, y: 0.01, width: 0.95, height: 0.98)
        let expanded = ObjectDetectionEngine.expand(normalizedRect: edgeRect, paddingFraction: 0.1)

        XCTAssertGreaterThanOrEqual(expanded.origin.x, 0.0)
        XCTAssertGreaterThanOrEqual(expanded.origin.y, 0.0)
        XCTAssertLessThanOrEqual(expanded.maxX, 1.0)
        XCTAssertLessThanOrEqual(expanded.maxY, 1.0)
    }

    func testConvertVisionRectToUIKit() {
        // Vision: (0.1, 0.2, 0.5, 0.3) -> UIKit: y = 1.0 - 0.2 - 0.3 = 0.5
        let visionRect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let uiKitRect = ObjectDetectionEngine.convertVisionRectToUIKit(visionRect)

        XCTAssertEqual(uiKitRect.origin.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(uiKitRect.origin.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(uiKitRect.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(uiKitRect.height, 0.3, accuracy: 0.001)
    }

    func testCropImageGeneratesValidCroppedImage() {
        // 创建一个 400x400 的测试图像，并在中心绘制一个红色方块
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format)
        let testImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))

            UIColor.red.setFill()
            ctx.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        }

        let targetROI = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = ObjectDetectionEngine.crop(image: testImage, to: targetROI, paddingFraction: 0.05)

        XCTAssertNotNil(cropped)
        guard let result = cropped else { return }

        // 裁剪后宽度与高度应该接近 400 * (0.5 + 2*0.05*0.5) = 220 像素
        XCTAssertGreaterThan(result.pixelWidth, 150)
        XCTAssertLessThanOrEqual(result.pixelWidth, 400)
        XCTAssertFalse(result.jpegData.isEmpty)
    }

    func testDetectTargetObjectOnSynthesizedImage() async throws {
        // 创建一个有明确前景物体的测试图（黑色背景，中间有明亮的绿色方块）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format)
        let testImage = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))

            UIColor.green.setFill()
            ctx.fill(CGRect(x: 75, y: 75, width: 150, height: 150))
        }

        guard let cgImage = testImage.cgImage else {
            XCTFail("无法生成 CGImage")
            return
        }

        let engine = ObjectDetectionEngine.shared
        let roi = try await engine.detectTargetObject(in: cgImage)

        // Apple Vision 应当能检出中心的绿色物体
        XCTAssertNotNil(roi)
        if let detected = roi {
            XCTAssertTrue(detected.isValid)
            XCTAssertGreaterThan(detected.normalizedRect.width, 0.1)
            XCTAssertGreaterThan(detected.normalizedRect.height, 0.1)
        }
    }
}
