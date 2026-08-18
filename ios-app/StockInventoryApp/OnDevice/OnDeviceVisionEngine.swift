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
    private var activeRecognitionID: UUID?

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

    /// 入库识别 Prompt：要求模型以单行紧凑 JSON 输出完整结构化字段，禁止冗余废话。
    static let inboundPrompt = """
    请识别图片中的库存商品/原材料。直接以单行紧凑 JSON 输出，不要输出任何思考过程或多余解释：
    {"名称":"商品品名","规格单位":"个/包/盒/瓶/箱/kg","品类":"分类(如食品/五金/日化/耗材)","保质期天数":365,"生产日期":"YYYY-MM-DD","保质期":"YYYY-MM-DD","条码":"","置信度":0.95}
    无法确定的字段留空字符串或填0。
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

    /// 最近一次推理的性能指标摘要（供 UI / 诊断日志观测）
    var latestMetricsSummary: String? {
        wrapper.latestMetrics?.summary
    }

    // MARK: - 加载（模型路径由 ModelManager 提供）

    /// 用指定 GGUF + mmproj 路径初始化端侧模型。全进程仅一次。
    func load(modelPath: String, mmprojPath: String) async {
        // 事前环境准入：不安全则绝不触碰 MTMDWrapper（C 层崩溃不可事后 catch）
        let env = OnDeviceSafeEnvironment.evaluate(phase: .modelLoad)
        AppLogger.shared.log(
            level: env.safe ? .info : .error,
            category: .ai,
            message: env.safe ? "MiniCPM-V 模型加载内存检查通过" : "MiniCPM-V 模型加载内存检查未通过",
            details: env.safe ? env.diagnosticSummary : "\(env.reason) | \(env.diagnosticSummary)"
        )
        guard env.safe else {
            self.unavailableReason = env.reason
            self.loadSuccess = false
            errorMessage = env.reason
            return
        }
        unavailableReason = ""
        errorMessage = ""
        do {
            let params = MTMDParams(
                modelPath: modelPath,
                mmprojPath: mmprojPath,
                nPredict: 64,
                nCtx: 1536,
                nThreads: MTMDParams.optimalThreadCount,
                temperature: 0.7,
                useGPU: false,
                mmprojUseGPU: false,
                warmup: false,
                nUbatch: 128
            )
            try await wrapper.initialize(with: params)
            wrapper.setModelVersion(46) // MiniCPM-V 4.6
            self.loadSuccess = true
            AppLogger.shared.log(
                level: .info,
                category: .ai,
                message: "MiniCPM-V 模型加载完成",
                details: "CPU (\(params.nThreads) threads), ctx=1536, batch=512, ubatch=128, output=64 tokens, vision<=448px"
            )
        } catch {
            errorMessage = error.localizedDescription
            loadSuccess = false
            AppLogger.shared.log(
                level: .error,
                category: .ai,
                message: "MiniCPM-V 模型初始化失败",
                details: error.localizedDescription
            )
        }
    }


    // MARK: - 识别

    /// 拍照识别：图片 Data → 临时 JPEG → llama.cpp 推理 → 解析 JSON。
    func recognize(imageData: Data, prompt: String = OnDeviceVisionEngine.inboundPrompt) async -> RecognitionResult {
        guard activeRecognitionID == nil else {
            AppLogger.shared.log(
                level: .error,
                category: .ai,
                message: "MiniCPM-V 已有识别任务运行中",
                details: "拒绝并发访问原生 llama 上下文"
            )
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true)
        }
        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        defer { activeRecognitionID = nil }

        guard loadSuccess else {
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }

        // 二次护栏：recognition 入口再确认环境安全
        let env = OnDeviceSafeEnvironment.evaluate(phase: .imageInference)
        AppLogger.shared.log(
            level: env.safe ? .info : .error,
            category: .ai,
            message: env.safe ? "MiniCPM-V 图片推理内存检查通过" : "MiniCPM-V 图片推理内存检查未通过",
            details: env.safe ? env.diagnosticSummary : "\(env.reason) | \(env.diagnosticSummary)"
        )
        guard env.safe else {
            self.unavailableReason = env.reason
            self.errorMessage = env.reason
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }
        unavailableReason = ""
        errorMessage = ""

        guard let preparedImage = OnDeviceVisionImagePreprocessor.prepare(imageData) else {
            let message = "MiniCPM-V 图片预处理失败，未进入原生推理"
            errorMessage = message
            AppLogger.shared.log(level: .error, category: .ai, message: message)
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                     recognizedName: nil)
        }
        AppLogger.shared.log(
            level: .info,
            category: .ai,
            message: "MiniCPM-V 单图输入已就绪",
            details: "input=\(imageData.count) bytes, \(preparedImage.diagnosticSummary)"
        )

        guard let url = saveTempJPEG(preparedImage.jpegData) else {
            AppLogger.shared.log(level: .error, category: .ai, message: "MiniCPM-V 临时图片写入失败")
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true,
                                      recognizedName: nil)
        }
        defer {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                AppLogger.shared.log(
                    level: .warning,
                    category: .ai,
                    message: "MiniCPM-V 临时图片清理失败",
                    details: error.localizedDescription
                )
            }
        }

        wrapper.clearKVCacheForNewTurn()
        let inferenceStartTime = Date()
        do {
            try await wrapper.addImageInBackground(url.path)
            try await wrapper.addTextInBackground(prompt)
            // 启用结构化 JSON 闭合早停：一旦识别出完整合法的 JSON 对象立即提前结束生成
            try await wrapper.startGeneration(earlyStopPredicate: { text in
                Self.isCompleteJSON(text)
            })
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.shared.log(
                level: .error,
                category: .ai,
                message: "MiniCPM-V 端侧推理失败",
                details: error.localizedDescription
            )
            return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true, recognizedName: nil)
        }

        let totalElapsed = Date().timeIntervalSince(inferenceStartTime)
        let metricsSummary = wrapper.latestMetrics?.summary ?? String(format: "total=%.2fs", totalElapsed)
        let parsed = Self.parseResult(wrapper.fullOutput, imageData: imageData)

        AppLogger.shared.log(
            level: .info,
            category: .ai,
            message: "MiniCPM-V 端侧推理与解析完成",
            details: "name=\(parsed.recognizedName ?? "无"), conf=\(parsed.confidence), metrics=\(metricsSummary), rawLength=\(wrapper.fullOutput.count)"
        )

        return parsed
    }

    func cancelCurrentRecognition(reason: String) {
        guard activeRecognitionID != nil else { return }
        wrapper.stopGeneration()
        AppLogger.shared.log(
            level: .warning,
            category: .ai,
            message: "已请求取消 MiniCPM-V 识别",
            details: reason
        )
    }

    // MARK: - 判定与解析

    /// 判定输出文本中是否已生成完整的闭合 JSON 结构（用于提前早停）
    static func isCompleteJSON(_ text: String) -> Bool {
        guard let start = text.range(of: "{"),
              let end = text.range(of: "}", options: .backwards),
              start.lowerBound < end.upperBound else {
            return false
        }
        let candidate = String(text[start.lowerBound...end.upperBound])
        guard let data = candidate.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // 确保至少存在核心字段且有内容
        let hasName = (dict["名称"] as? String)?.isEmpty == false
        let hasUnit = (dict["规格单位"] as? String)?.isEmpty == false
        return hasName || hasUnit || dict.count >= 2
    }

    /// 从模型输出里容错提取 JSON 并映射到 RecognitionResult。
    static func parseResult(_ text: String, imageData: Data) -> RecognitionResult {
        let cleaned = cleanOutput(text)

        // 1. 尝试直接解析标准 JSON
        if let dict = extractJSONDictionary(from: cleaned) {
            return buildResult(from: dict, rawText: text)
        }

        // 2. 尝试修复未闭合的截断 JSON
        if let repairedDict = tryRepairAndExtractJSON(from: cleaned) {
            return buildResult(from: repairedDict, rawText: text)
        }

        // 3. 正则保底提取字段
        if let regexDict = extractByRegex(from: cleaned) {
            return buildResult(from: regexDict, rawText: text)
        }

        // 4. 完全未匹配到结构化数据：提取非空纯文本片段兜底
        let fallbackName = cleaned.isEmpty ? nil : String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return RecognitionResult(
            confidence: 0.3,
            mode: .vision,
            needsLearning: true,
            recognizedName: fallbackName
        )
    }

    // MARK: - 容错解析内部函数

    private static func cleanOutput(_ text: String) -> String {
        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥离 Markdown 代码块 ```json ... ```
        if str.hasPrefix("```json") {
            str = String(str.dropFirst(7))
        } else if str.hasPrefix("```") {
            str = String(str.dropFirst(3))
        }
        if str.hasSuffix("```") {
            str = String(str.dropLast(3))
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONDictionary(from text: String) -> [String: Any]? {
        guard let start = text.range(of: "{"),
              let end = text.range(of: "}", options: .backwards),
              start.lowerBound < end.upperBound else {
            return nil
        }
        let jsonSub = text[start.lowerBound...end.upperBound]
        guard let data = jsonSub.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func tryRepairAndExtractJSON(from text: String) -> [String: Any]? {
        guard let start = text.range(of: "{") else { return nil }
        var candidate = String(text[start.lowerBound...])

        // 补齐可能缺失的右引号和右大括号
        let quoteCount = candidate.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            candidate += "\""
        }
        if !candidate.hasSuffix("}") {
            candidate += "}"
        }

        guard let data = candidate.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func extractByRegex(from text: String) -> [String: Any]? {
        var dict: [String: Any] = [:]

        let extractValue = { (pattern: String) -> String? in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let nsString = text as NSString
            guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)),
                  match.numberOfRanges > 1 else { return nil }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let name = extractValue("\"(?:名称|name|sku_name|商品名称|品名)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["名称"] = name
        }
        if let unit = extractValue("\"(?:规格单位|单位|unit|unit_name|包装单位)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["规格单位"] = unit
        }
        if let cat = extractValue("\"(?:品类|category|category_name|分类)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["品类"] = cat
        }
        if let daysStr = extractValue("\"(?:保质期天数|保质期天|shelf_life_days|shelf_life)\"\\s*:\\s*([0-9]+)") {
            dict["保质期天数"] = Int(daysStr)
        }
        if let code = extractValue("\"(?:条码|barcode|条形码)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["条码"] = code
        }
        if let prod = extractValue("\"(?:生产日期|prod_date|production_date)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["生产日期"] = prod
        }
        if let exp = extractValue("\"(?:保质期|到期日期|exp_date|expiration_date)\"\\s*:\\s*\"([^\"]+)\"") {
            dict["保质期"] = exp
        }
        if let confStr = extractValue("\"(?:置信度|confidence)\"\\s*:\\s*([0-9.]+)"),
           let conf = Double(confStr) {
            dict["置信度"] = conf
        }

        return dict.isEmpty ? nil : dict
    }

    private static func buildResult(from dict: [String: Any], rawText: String) -> RecognitionResult {
        let str = { (keys: [String]) -> String? in
            for k in keys {
                if let v = dict[k] {
                    if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let n = v as? NSNumber { return n.stringValue }
                }
            }
            return nil
        }

        let name = str(["名称", "sku_name", "name", "商品名称", "品名"])
        let unit = str(["规格单位", "unit", "unit_name", "单位", "包装单位"])
        let category = str(["品类", "category", "category_name", "分类"])
        let barcode = str(["条码", "barcode", "条形码"])

        var shelfLifeDays: Int? = nil
        for k in ["保质期天数", "shelf_life_days", "保质期天", "shelf_life"] {
            if let v = dict[k] {
                if let n = v as? NSNumber { shelfLifeDays = n.intValue; break }
                if let s = v as? String {
                    let digits = s.filter { $0.isNumber }
                    if let d = Int(digits), d > 0 {
                        // 如果包含“月”则乘 30
                        if s.contains("月") || s.contains("month") {
                            shelfLifeDays = d * 30
                        } else if s.contains("年") || s.contains("year") {
                            shelfLifeDays = d * 365
                        } else {
                            shelfLifeDays = d
                        }
                        break
                    }
                }
            }
        }

        let prod = str(["生产日期", "prod_date", "production_date"]).flatMap { Self.parseDate($0) }
        let exp = str(["保质期", "到期日期", "exp_date", "expiration_date"]).flatMap { Self.parseDate($0) }
        let conf = (dict["置信度"] as? NSNumber)?.doubleValue ?? ((dict["confidence"] as? Double) ?? ((dict["置信度"] as? Double) ?? 0.5))

        return RecognitionResult(
            sku: nil,
            packagingUnit: nil,
            confidence: conf,
            mode: .vision,
            needsLearning: conf < 0.6,
            recognizedName: name,
            recognizedUnit: unit,
            recognizedCategory: category,
            recognizedShelfLifeDays: shelfLifeDays,
            recognizedBarcode: barcode,
            productionDate: prod,
            expirationDate: exp
        )
    }

    // MARK: - 工具

    private func saveTempJPEG(_ data: Data) -> URL? {
        return autoreleasepool {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("ondevice_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 1000...9999)).jpg")
            guard (try? data.write(to: url)) != nil else { return nil }
            return url
        }
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
