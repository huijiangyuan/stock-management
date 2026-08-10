import XCTest
@testable import StockInventoryApp

final class OnDeviceSafetyTests: XCTestCase {
    func testModelLoadRejectsInsufficientAvailableMemory() {
        let result = OnDeviceSafeEnvironment.evaluate(
            phase: .modelLoad,
            availableMemory: 2_699_999_999,
            physicalMemory: 8_000_000_000
        )

        XCTAssertFalse(result.safe)
        XCTAssertTrue(result.reason.contains("模型加载内存不足"))
        XCTAssertTrue(result.reason.contains("LiveContainer"))
    }

    func testModelLoadAcceptsThreshold() {
        let result = OnDeviceSafeEnvironment.evaluate(
            phase: .modelLoad,
            availableMemory: OnDeviceSafeEnvironment.modelLoadMinimumAvailableBytes,
            physicalMemory: OnDeviceSafeEnvironment.recommendedDeviceMemoryBytes
        )

        XCTAssertTrue(result.safe)
        XCTAssertTrue(result.reason.isEmpty)
    }

    func testInferenceUsesSeparateHeadroomThreshold() {
        let result = OnDeviceSafeEnvironment.evaluate(
            phase: .imageInference,
            availableMemory: OnDeviceSafeEnvironment.inferenceMinimumAvailableBytes,
            physicalMemory: 8_000_000_000
        )

        XCTAssertTrue(result.safe)
        XCTAssertEqual(result.minimumAvailableBytes, 1_500_000_000)
    }

    func testRejectsDeviceBelowOfficialRecommendation() {
        let result = OnDeviceSafeEnvironment.evaluate(
            phase: .modelLoad,
            availableMemory: 3_000_000_000,
            physicalMemory: 5_000_000_000
        )

        XCTAssertFalse(result.safe)
        XCTAssertTrue(result.reason.contains("至少 6 GB"))
    }
}
