import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import StockInventoryApp

final class OnDeviceVisionImagePreprocessorTests: XCTestCase {
    func testPrepareLimitsEveryInputEdgeToVisionEncoderSize() throws {
        let input = try makeJPEG(width: 1600, height: 900)

        let result = try XCTUnwrap(OnDeviceVisionImagePreprocessor.prepare(input))

        XCTAssertLessThanOrEqual(result.pixelWidth, OnDeviceVisionImagePreprocessor.maximumPixelDimension)
        XCTAssertLessThanOrEqual(result.pixelHeight, OnDeviceVisionImagePreprocessor.maximumPixelDimension)
        XCTAssertEqual(result.pixelWidth, OnDeviceVisionImagePreprocessor.maximumPixelDimension)
        XCTAssertGreaterThan(result.jpegData.count, 0)
    }

    func testPrepareReturnsNilForInvalidImageData() {
        XCTAssertNil(OnDeviceVisionImagePreprocessor.prepare(Data("not an image".utf8)))
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "OnDeviceVisionImagePreprocessorTests", code: 1)
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "OnDeviceVisionImagePreprocessorTests", code: 2)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "OnDeviceVisionImagePreprocessorTests", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "OnDeviceVisionImagePreprocessorTests", code: 4)
        }
        return output as Data
    }
}
