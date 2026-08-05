import Foundation
import ImageIO
import UIKit

struct ProcessedCapturedImage: Sendable, Equatable {
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// 将相机原图一次性解码、按 EXIF 方向旋转并缩放，供向量模型与 VLM 复用同一份数据。
actor CapturedImageProcessor {
    enum ProcessingError: LocalizedError, Equatable {
        case invalidImageData
        case thumbnailCreationFailed
        case jpegEncodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "相机返回的数据不是有效图片"
            case .thumbnailCreationFailed:
                return "相机图片解码或缩放失败"
            case .jpegEncodingFailed:
                return "相机图片 JPEG 编码失败"
            }
        }
    }

    private let maximumPixelSize: Int
    private let compressionQuality: CGFloat

    init(maximumPixelSize: Int = 1_024, compressionQuality: CGFloat = 0.82) {
        self.maximumPixelSize = maximumPixelSize
        self.compressionQuality = compressionQuality
    }

    func process(_ imageData: Data) throws -> ProcessedCapturedImage {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingError.invalidImageData
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProcessingError.thumbnailCreationFailed
        }

        let image = UIImage(cgImage: cgImage)
        guard let jpegData = image.jpegData(compressionQuality: compressionQuality) else {
            throw ProcessingError.jpegEncodingFailed
        }

        return ProcessedCapturedImage(
            jpegData: jpegData,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }
}
