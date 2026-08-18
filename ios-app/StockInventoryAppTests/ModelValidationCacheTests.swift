import XCTest
@testable import StockInventoryApp

final class ModelValidationCacheTests: XCTestCase {
    private var tempFileURL: URL!
    private var testDefaults: UserDefaults!
    private var cache: ModelValidationCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suiteName = "test.validation.cache.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        cache = ModelValidationCache(defaults: testDefaults)

        let tempDir = FileManager.default.temporaryDirectory
        tempFileURL = tempDir.appendingPathComponent("test_model_\(UUID().uuidString).gguf")
        try "test data for checksum validation".data(using: .utf8)!.write(to: tempFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFileURL)
        testDefaults.removePersistentDomain(forName: testDefaults.description)
        try super.tearDownWithError()
    }

    func testValidationCacheHitWhenFileUnchanged() {
        let expectedHash = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
        
        // 初始无缓存
        XCTAssertFalse(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))

        // 记录校验
        cache.recordValid(for: tempFileURL, verifiedHash: expectedHash)

        // 再次检查应命中缓存
        XCTAssertTrue(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))
        XCTAssertTrue(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash.uppercased()))
    }

    func testValidationCacheMissOnExpectedHashMismatch() {
        let actualHash = "1111111111111111111111111111111111111111111111111111111111111111"
        let differentHash = "2222222222222222222222222222222222222222222222222222222222222222"

        cache.recordValid(for: tempFileURL, verifiedHash: actualHash)
        XCTAssertFalse(cache.isValidationValid(for: tempFileURL, expectedHash: differentHash))
    }

    func testValidationCacheInvalidatesWhenFileModified() throws {
        let expectedHash = "3333333333333333333333333333333333333333333333333333333333333333"
        cache.recordValid(for: tempFileURL, verifiedHash: expectedHash)
        XCTAssertTrue(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))

        // 修改文件内容（大小发生变化）
        try "appended extra content to alter file size".data(using: .utf8)!.write(to: tempFileURL)

        // 缓存应立即失效
        XCTAssertFalse(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))
    }

    func testManualInvalidateAndClearAll() {
        let expectedHash = "4444444444444444444444444444444444444444444444444444444444444444"
        cache.recordValid(for: tempFileURL, verifiedHash: expectedHash)
        XCTAssertTrue(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))

        cache.invalidate(for: tempFileURL)
        XCTAssertFalse(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))

        cache.recordValid(for: tempFileURL, verifiedHash: expectedHash)
        XCTAssertTrue(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))

        cache.clearAll()
        XCTAssertFalse(cache.isValidationValid(for: tempFileURL, expectedHash: expectedHash))
    }
}
