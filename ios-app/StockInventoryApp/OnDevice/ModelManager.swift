//
//  ModelManager.swift
//  库存管理 App · 端侧 MiniCPM-V 4.6 模型管理与下载
//
//  负责：从 ModelScope（国内镜像，默认）/ HuggingFace（备选）/ 自定义 URL 下载
//  GGUF + mmproj；断点续传 + 进度 + 失败重试；下载后流式算 sha256 与编译进
//  二进制的预期哈希常量比对（fail-closed：不匹配则删除文件并拒绝加载）；
//  扫描 App Documents（含 Files App 手动放入）做兜底。校验通过后调用
//  OnDeviceVisionEngine.load 在本地加载推理引擎。重活（sha256 / 加载）均不在主线程。
//

import Foundation
import Observation
import CommonCrypto

@MainActor
@Observable
final class ModelManager {

    static let shared = ModelManager()

    // MARK: - 4.6 实际文件名（与 OpenBMB 官方仓库一致）

    static let llmFileName = "MiniCPM-V-4_6-Q4_K_M.gguf"
    static let mmprojFileName = "mmproj-model-f16.gguf"

    // MARK: - 预期 sha256（编译进二进制常量；取自 ModelScope 官方仓库文件清单）

    /// 安全审计要求：预期哈希须编译进二进制（非 plist / UserDefaults），防止被篡改绕过。
    /// 值来自 https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4.6-gguf/repo/files
    static let expectedLLMSha256 = "6b0c74962c44bc6bf4b655b9b02c13eda9d5a0491543ae976d1ac18e4b7892e2"
    static let expectedMmprojSha256 = "ca931d861d0801d9003e50697cd764721a334107c0e0415a51168ee1938462de"

    // MARK: - 官方域名白名单（默认源）

    private static let allowedHosts = ["modelscope.cn", "huggingface.co"]

    // MARK: - 下载源

    enum Source: String, CaseIterable, Identifiable {
        case modelScope = "ModelScope（国内镜像）"
        case huggingFace = "HuggingFace"
        case `custom` = "自定义 URL"
        var id: String { rawValue }
        var base: String? {
            switch self {
            case .modelScope: return "https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.6-gguf/resolve/master"
            case .huggingFace: return "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main"
            case .custom: return nil
            }
        }
    }

    // MARK: - 对外状态

    enum DownloadState: Equatable {
        case idle
        case downloading(Double)   // 进度 0..1
        case verifying
        case completed
        case loaded
        case failed(String)
    }

    var state: DownloadState = .idle
    var message: String = ""
    var modelPresent: Bool = false
    var loaded: Bool { OnDeviceVisionEngine.shared.loadSuccess }

    // MARK: - 内部

    private var session: URLSession!
    private var currentTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var retryCount = 0
    private let maxRetry = 3
    private struct PendingFile { let url: URL; let dest: URL }
    private var pending: [PendingFile] = []
    private var currentDest: URL?
    private var lastLocation: URL?

    var modelsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
    }

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 900
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: DownloadDelegate(manager: self), delegateQueue: nil)
        Task { await refreshPresence() }
    }

    // MARK: - 扫描（已下载的 或 Files App 手动放入 Documents 的）

    /// 在 models/ 与 Documents 根目录查找 LLM 与 mmproj 文件（手动兜底）。
    func scanModelFiles() -> (llm: URL?, mmproj: URL?) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dirs = [modelsDir, docs]
        var llm: URL?, mmproj: URL?
        for d in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for f in files where !f.hasDirectoryPath {
                let n = f.lastPathComponent
                if n == Self.llmFileName || (n.hasSuffix(".gguf") && !n.lowercased().contains("mmproj")) {
                    if llm == nil { llm = f }
                } else if n == Self.mmprojFileName || n.lowercased().contains("mmproj") {
                    if mmproj == nil { mmproj = f }
                }
            }
        }
        return (llm, mmproj)
    }

    func refreshPresence() {
        let f = scanModelFiles()
        modelPresent = f.llm != nil && f.mmproj != nil
        if case .loaded = state, !OnDeviceVisionEngine.shared.loadSuccess {
            state = modelPresent ? .completed : .idle
        } else if case .idle = state {
            message = modelPresent
                ? "检测到模型文件，可加载。"
                : "尚未下载模型：请下载，或用 iOS 文件 App 把两个 GGUF 放入 App 的「资料」(Documents)。"
        }
    }

    // MARK: - 下载

    func download(source: Source, customURL: String? = nil) {
        guard currentTask == nil else { message = "已有下载进行中"; return }
        var llmURL: URL?, mmprojURL: URL?
        switch source {
        case .modelScope, .huggingFace:
            guard let base = source.base,
                  let lu = URL(string: base + "/" + Self.llmFileName),
                  let mu = URL(string: base + "/" + Self.mmprojFileName),
                  Self.isOfficialHost(lu), Self.isOfficialHost(mu) else {
                state = .failed("下载地址不在官方域名白名单内"); return
            }
            llmURL = lu; mmprojURL = mu
        case .custom:
            guard let raw = customURL, let u = URL(string: raw.trimmingCharacters(in: .whitespaces)),
                  u.scheme == "https", !isPrivateHost(u) else {
                state = .failed("自定义地址必须为 https，且不能是内网 / 本机地址"); return
            }
            llmURL = u
            mmprojURL = URL(string: u.deletingLastPathComponent().absoluteString + Self.mmprojFileName)
        }
        guard let llmURL, let mmprojURL else { state = .failed("下载地址无效"); return }

        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        pending = [
            PendingFile(url: llmURL, dest: modelsDir.appendingPathComponent(Self.llmFileName)),
            PendingFile(url: mmprojURL, dest: modelsDir.appendingPathComponent(Self.mmprojFileName))
        ]
        retryCount = 0
        resumeData = nil
        state = .downloading(0)
        message = "开始下载 MiniCPM-V 4.6 模型（约 1.6 GB），建议在 Wi-Fi 下进行…"
        startNext()
    }

    private func startNext() {
        if pending.isEmpty {
            // 全部下载完：后台校验两个文件（避免阻塞主线程）
            Task { await finalizeDownload() }
            return
        }
        let p = pending[0]
        currentDest = p.dest
        let req = URLRequest(url: p.url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let rd = resumeData {
            currentTask = session.downloadTask(withResumeData: rd)
        } else {
            currentTask = session.downloadTask(with: req)
        }
        resumeData = nil
        currentTask?.resume()
    }

    /// 下载完成后的最终校验（后台线程）：sha256 不匹配则 fail-closed 删除文件并拒绝。
    private func finalizeDownload() async {
        let f = scanModelFiles()
        guard let llm = f.llm, let mp = f.mmproj else {
            state = .failed("下载后未找到模型文件"); return
        }
        let ok = await Task.detached { () -> Bool in
            ModelManager.verifyFile(llm, expected: ModelManager.expectedLLMSha256) &&
            ModelManager.verifyFile(mp, expected: ModelManager.expectedMmprojSha256)
        }.value
        if !ok {
            try? FileManager.default.removeItem(at: llm)
            try? FileManager.default.removeItem(at: mp)
            refreshPresence()
            state = .failed("校验失败（sha256 不匹配），已删除文件以防被篡改。请重新下载或换可信来源。")
            return
        }
        state = .completed
        message = "下载完成且校验通过，点击「加载模型」即可在本地运行识别。"
        refreshPresence()
    }

    // MARK: - 加载（后台校验 + 调 OnDeviceVisionEngine）

    /// 校验（内置预期哈希）并加载已存在的模型文件。供设置页「加载」与识别流程自动调用。
    func load() async {
        let f = scanModelFiles()
        guard let llm = f.llm, let mp = f.mmproj else {
            state = .failed("未找到模型文件，请先下载或用 Files App 放入 Documents"); return
        }
        state = .verifying
        let ok = await Task.detached { () -> Bool in
            ModelManager.verifyFile(llm, expected: ModelManager.expectedLLMSha256) &&
            ModelManager.verifyFile(mp, expected: ModelManager.expectedMmprojSha256)
        }.value
        if !ok {
            try? FileManager.default.removeItem(at: llm)
            try? FileManager.default.removeItem(at: mp)
            refreshPresence()
            state = .failed("校验失败（sha256 不匹配），已删除文件以防被篡改。")
            return
        }
        // OnDeviceVisionEngine.load 内部在后台线程做模型初始化（warmup），await 不阻塞主线程
        await OnDeviceVisionEngine.shared.load(modelPath: llm.path, mmprojPath: mp.path)
        if OnDeviceVisionEngine.shared.loadSuccess {
            state = .loaded
            modelPresent = true
            message = "模型已加载，端侧识别可用。"
        } else {
            state = .failed("模型加载失败：\(OnDeviceVisionEngine.shared.errorMessage)")
        }
    }

    /// 由识别流程在端侧可用时调用：若文件存在且未加载则自动加载。
    func ensureLoaded() async {
        if OnDeviceVisionEngine.shared.loadSuccess { return }
        let f = scanModelFiles()
        guard f.llm != nil, f.mmproj != nil else { return }
        await load()
    }

    // MARK: - Delegate 回调（从 DownloadDelegate 经 MainActor 调用）

    fileprivate func didWrite(progress: Double) {
        if case .downloading = state { state = .downloading(progress) }
    }

    fileprivate func didFinishDownloading(to location: URL) {
        lastLocation = location
    }

    fileprivate func didComplete(task: URLSessionTask, error: Error?) {
        if let err = error {
            if let rd = (err as NSError).userInfo[NSURLSessionDownloadTaskResumeDataErrorKey] as? Data {
                resumeData = rd
            }
            if retryCount < maxRetry, resumeData != nil {
                retryCount += 1
                message = "网络中断，正在重试（\(retryCount)/\(maxRetry)）…"
                startNext()
            } else {
                state = .failed("下载失败：\(err.localizedDescription)")
                currentTask = nil
            }
            return
        }
        guard let loc = lastLocation, let dest = currentDest else {
            state = .failed("下载临时文件缺失"); return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: loc, to: dest)
        } catch {
            state = .failed("保存失败：\(error.localizedDescription)"); return
        }
        lastLocation = nil
        currentTask = nil
        pending.removeFirst()
        startNext()
    }

    // MARK: - 工具（静态，便于后台线程调用）

    private static func isOfficialHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 屏蔽内网 / 本机地址（安全审计要求）：自定义 URL 只允许公网 https。
    private func isPrivateHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        let blocked = ["localhost", "127.", "10.", "192.168.", "172.16.", "172.17.",
                       "172.18.", "172.19.", "172.2", "172.30.", "172.31.",
                       "169.254.", "0.0.0.0", "::1", "[::1]"]
        return blocked.contains { host.hasPrefix($0) }
    }

    /// 流式 sha256（CommonCrypto，避免大文件整块读入内存）。
    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        let bufSize = 1 << 20
        while true {
            let data = try? handle.read(upToCount: bufSize)
            guard let data, !data.isEmpty else { break }
            data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    CC_SHA256_Update(&ctx, base, CC_LONG(data.count))
                }
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyFile(_ url: URL, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let got = sha256Hex(of: url) else { return false }
        return got.lowercased() == expected.lowercased()
    }

    /// 供 UI 展示预期哈希。
    var expectedHashDisplay: String {
        "LLM:    \(Self.expectedLLMSha256.prefix(16))…\n" +
        "mmproj: \(Self.expectedMmprojSha256.prefix(16))…"
    }
}

// MARK: - URLSession 下载代理（进度 / 完成）

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: ModelManager?
    init(manager: ModelManager) { self.manager = manager }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.manager?.didWrite(progress: p) }
    }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        Task { @MainActor in self.manager?.didFinishDownloading(to: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in self.manager?.didComplete(task: task, error: error) }
    }
}
