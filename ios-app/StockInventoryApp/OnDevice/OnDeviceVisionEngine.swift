//
//  OnDeviceVisionEngine.swift
//  库存管理 App · 端侧 MiniCPM-V 4.6 视觉识别引擎
//
//  复用 MiniCPM-V-Apps 的 MTMDWrapper（llama.cpp 原生推理桥），
//  在本地用 MiniCPM-V 4.6 GGUF 做摄像头物料识别，数据不出设备。
//  单例全局只加载一次（llama state machine 不可重复 init）。
//

import Foundation
import Combine
import SwiftData

/// 端侧视觉识别引擎：封装 MTMDWrapper（llama.cpp / MiniCPM-V 4.6）。
@MainActor
final class OnDeviceVisionEngine: ObservableObject {

    // MARK: - 单例

    static let shared = OnDeviceVisionEngine()

    // MARK: - 底层推理封装（来自 MiniCPM-V-Apps 的 MTMDWrapper）

    private let wrapper = MTMDWrapper()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 对外状态

    @Published var outputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var loadSuccess: Bool = false
    @Published var errorMessage: String = ""
    /// 端侧不可用的引导原因（环境准入护栏命中时填写，供 UI 透出）。
    @Published var unavailableReason: String = ""

    /// 端侧引擎当前是否可用：已加载且环境准入通过。供识别流程决策用。
    var onDeviceUsable: Bool { loadSuccess && unavailableReason.isEmpty }

    /// 模型文件名常量（MiniCPM-V 4.6 官方实际文件名）
    static let modelFileName = "MiniCPM-V-4_6-Q4_K_M.gguf"
    static let mmprojFileName = "mmproj-model-f16.gguf"

    // MARK: - Prompt

    /// 入库识别 Prompt：要求模型以 JSON 输出结构化字段。
    static let inboundPrompt = """
    请识别这张图片中的库存原材料/商品，并尽量以 JSON 输出：\
    {"名称":"","规格单位":"","生产日期":"","保质期":"","置信度":0.0}。\
    无法确定的字段留空或填0。生产日期与保质期若为"2026-08-01"格式。
    """

    // MARK: - Init

    private init() {
        wrapper.$fullOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.outputText = text }
            .store(in: &cancellables)

        wrapper.$generationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .generating: self?.isGenerating = true
                case .completed, .cancelled, .idle: self?.isGenerating = false
                case .failed(let err): self?.isGenerating = false; self?.errorMessage = err.localizedDescription
                default: self?.isGenerating = false
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 加载（模型路径由 ModelManager 提供）

    /// 用指定 GGUF + mmproj 路径初始化端侧模型。全进程仅一次。
    func load(modelPath: String, mmprojPath: String) async {
        // 事前环境准入：不安全则绝不触碰 MTMDWrapper（C 层崩溃不可事后 catch）
        let env = OnDeviceSafeEnvironment.evaluate()
        guard env.safe else {
            self.unavailableReason = env.reason
            self.loadSuccess = false
            errorMessage = env.reason
            return
        }
        do {
            let tier = DeviceMemoryTier.current
            let params = MTMDParams(
                modelPath: modelPath,
                mmprojPath: mmprojPath,
                nCtx: 4096,
                nThreads: 4,
                temperature: 0.7,
                useGPU: true,
                mmprojUseGPU: true,
                warmup: true,
                nUbatch: tier.recommendedUbatch,
                imageMaxSliceNums: -1,
                imageMaxTokens: tier.recommendedImageMaxTokens
            )
            try await wrapper.initialize(with: params)
            wrapper.setModelVersion(46) // MiniCPM-V 4.6
            self.loadSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            loadSuccess = false
        }
    }

    // MARK: - 识别

    /// 拍照识别：图片 Data → 临时 JPEG → llama.cpp 推理 → 解析 JSON。
    func recognize(imageData: Data, prompt: String = OnDeviceVisionEngine.inboundPrompt) async -> RecognitionResult {
        guard loadSuccess else {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }

        // 二次护栏：recognition 入口再确认环境安全（loadSuccess 可能来自更早的
        // 安全环境；运行期内存压力也可能使本机变为不安全）。不安全则直接兜底，
        // 绝不触碰 wrapper，避免进入 C/Metal 层触发原生崩溃。
        let env = OnDeviceSafeEnvironment.evaluate()
        guard env.safe else {
            self.unavailableReason = env.reason
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }

        guard let url = saveTempJPEG(imageData) else {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }

        wrapper.clearKVCacheForNewTurn()
        do {
            try await wrapper.addImageInBackground(url.path)
            try await wrapper.addTextInBackground(prompt)
            try await wrapper.startGeneration()
        } catch {
            errorMessage = error.localizedDescription
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true, recognizedName: nil)
        }

        // 直接读 wrapper.fullOutput（源真相）：startGeneration 现已 await 到生成
        // 结束，fullOutput 已在主线程填好。避免依赖 Combine sink → outputText 的
        // 异步投递在 parse 时尚未到达，从而重蹈"安全环境也返回空结果"的覆辙。
        return Self.parseResult(wrapper.fullOutput, imageData: imageData)
    }

    // MARK: - 解析

    /// 从模型输出里抠 JSON，映射到 RecognitionResult。
    private static func parseResult(_ text: String, imageData: Data) -> RecognitionResult {
        guard let start = text.range(of: "{"),
              let end = text.range(of: "}", options: .backwards),
              let data = text[start.lowerBound...end.upperBound].data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 没解析到 JSON：仍带回原文，标记需要人工确认
            return RecognitionResult(confidence: 0.3, mode: .vision, needsLearning: true,
                                      recognizedName: text.isEmpty ? nil : String(text.prefix(40)))
        }

        let str = { (k: String) -> String? in
            guard let v = dict[k] else { return nil }
            if let s = v as? String, !s.isEmpty { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }

        let name = str("名称")
        let unit = str("规格单位")
        let prod = str("生产日期").flatMap { Self.parseDate($0) }
        let exp = str("保质期").flatMap { Self.parseDate($0) }
        let conf = (dict["置信度"] as? NSNumber)?.doubleValue ?? 0.5

        return RecognitionResult(
            confidence: conf,
            mode: .vision,
            needsLearning: conf < 0.6,
            recognizedName: name,
            productionDate: prod,
            expirationDate: exp
        )
    }

    // MARK: - 工具

    private func saveTempJPEG(_ data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("ondevice_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 1000...9999)).jpg")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private static func parseDate(_ s: String) -> Date? {
        let fmts = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd"]
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - 机型内存档位（简化版 MBDeviceMemoryProbe，写死保守值）

enum DeviceMemoryTier {
    case tiny    // 4 GB
    case small   // 6 GB
    case medium  // 8 GB
    case large   // 12+ GB

    var recommendedUbatch: Int {
        switch self {
        case .tiny:  return 128
        case .small: return 256
        case .medium: return 512
        case .large: return 1024
        }
    }

    var recommendedImageMaxTokens: Int {
        switch self {
        case .tiny:  return 256
        case .small: return -1
        case .medium: return -1
        case .large: return -1
        }
    }

    static let current: DeviceMemoryTier = {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / 1_073_741_824.0
        if gb < 5 { return .tiny }
        if gb < 7 { return .small }
        if gb < 10 { return .medium }
        return .large
    }()
}
