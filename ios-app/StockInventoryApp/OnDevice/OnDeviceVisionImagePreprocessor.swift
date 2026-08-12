//
//  OnDeviceVisionImagePreprocessor.swift
//  库存管理 App · MiniCPM-V 单图输入约束
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 在进入 mtmd 前，将库存拍照规范为 MiniCPM-V 4.6 的单张视觉输入。
///
/// upstream mtmd 对 MiniCPM-V 会在任一边长大于 vision encoder `image_size`
/// （本模型为 448）时自行切图，且当前公开 API 没有可靠的运行时切片上限。
/// 因此必须在 Swift 层物理缩图；这比一个不会传入 mtmd 的配置字段可靠。
enum OnDeviceVisionImagePreprocessor {
    static let maximumPixelDimension = 448
    static let jpegCompressionQuality: CGFloat = 0.72

    struct PreparedImage {
        let jpegData: Data
        let pixelWidth: Int
        let pixelHeight: Int

        var diagnosticSummary: String {
            "jpeg=\(jpegData.count) bytes, pixels=\(pixelWidth)x\(pixelHeight), max=\(OnDeviceVisionImagePreprocessor.maximumPixelDimension)"
        }
    }

    static func prepare(_ imageData: Data) -> PreparedImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }

            return PreparedImage(
                jpegData: output as Data,
                pixelWidth: image.width,
                pixelHeight: image.height
            )
        }
    }
}
