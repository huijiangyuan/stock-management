//
//  ModelValidationCache.swift
//  库存管理 App · 端侧模型 SHA-256 校验缓存
//
//  通过文件元数据（路径、大小、修改时间）与预期哈希建立安全校验收据（Receipt）。
//  只要文件未发生任何字节或时间变动，即可毫秒级复用校验结论；
//  文件新增、被修改或元数据不匹配时，自动失效并重新执行完整 SHA-256 流式校验。
//

import Foundation

/// 模型文件的安全校验收据
struct ModelValidationReceipt: Codable, Equatable, Sendable {
    let filePath: String
    let fileSize: UInt64
    let modificationTimeInterval: TimeInterval
    let verifiedSha256: String
    let validatedAt: Date
}

/// 模型校验缓存管理
final class ModelValidationCache: @unchecked Sendable {
    static let shared = ModelValidationCache()

    private let userDefaultsKey = "com.stockmgmt.model_validation_receipts"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 检查指定文件是否已有有效且未失效的校验收据
    /// - Parameters:
    ///   - fileURL: 模型文件本地路径
    ///   - expectedHash: 预期 SHA-256（小写）
    /// - Returns: 是否通过校验且有效
    func isValidationValid(for fileURL: URL, expectedHash: String) -> Bool {
        guard let expected = sanitize(expectedHash), !expected.isEmpty else { return true }
        guard let meta = fileMetadata(for: fileURL) else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard let receipt = loadReceipts()[fileURL.path] else { return false }

        let isValid = receipt.fileSize == meta.size
            && abs(receipt.modificationTimeInterval - meta.mtime) < 0.001
            && receipt.verifiedSha256.lowercased() == expected.lowercased()

        return isValid
    }

    /// 记录指定文件的安全校验成功收据
    /// - Parameters:
    ///   - fileURL: 模型文件本地路径
    ///   - verifiedHash: 实际校验通过的 SHA-256
    func recordValid(for fileURL: URL, verifiedHash: String) {
        guard let hash = sanitize(verifiedHash), !hash.isEmpty else { return }
        guard let meta = fileMetadata(for: fileURL) else { return }

        lock.lock()
        defer { lock.unlock() }

        var receipts = loadReceipts()
        receipts[fileURL.path] = ModelValidationReceipt(
            filePath: fileURL.path,
            fileSize: meta.size,
            modificationTimeInterval: meta.mtime,
            verifiedSha256: hash.lowercased(),
            validatedAt: Date()
        )
        saveReceipts(receipts)
    }

    /// 使指定文件的校验收据失效
    func invalidate(for fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }

        var receipts = loadReceipts()
        if receipts.removeValue(forKey: fileURL.path) != nil {
            saveReceipts(receipts)
        }
    }

    /// 清空所有校验收据
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - 内部辅助

    private struct FileMeta {
        let size: UInt64
        let mtime: TimeInterval
    }

    private func fileMetadata(for url: URL) -> FileMeta? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return FileMeta(size: size, mtime: modDate.timeIntervalSince1970)
    }

    private func loadReceipts() -> [String: ModelValidationReceipt] {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: ModelValidationReceipt].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveReceipts(_ receipts: [String: ModelValidationReceipt]) {
        if let data = try? JSONEncoder().encode(receipts) {
            defaults.set(data, forKey: userDefaultsKey)
        }
    }

    private func sanitize(_ hash: String?) -> String? {
        guard let h = hash?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else {
            return nil
        }
        return h.lowercased()
    }
}
