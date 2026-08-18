//
//  MTMDWrapper.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import Combine


/// MTMD 生成推理性能指标
public struct MTMDInferenceMetrics: Sendable, Equatable {
    public let decodeDuration: TimeInterval
    public let generatedTokenCount: Int
    public let tokensPerSecond: Double
    public let earlyStopped: Bool

    public var summary: String {
        String(format: "decode=%.2fs (%d tokens, %.1f tok/s%@)",
               decodeDuration,
               generatedTokenCount,
               tokensPerSecond,
               earlyStopped ? ", 早停" : "")
    }
}

/// MTMD 多模态推理包装器
@MainActor
public class MTMDWrapper: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 当前输出 Token
    @Published public private(set) var currentToken: MTMDToken = .empty
    
    /// 完整的输出内容
    @Published public private(set) var fullOutput: String = ""
    
    /// 生成状态
    @Published public private(set) var generationState: MTMDGenerationState = .idle
    
    /// 初始化状态
    @Published public private(set) var initializationState: MTMDInitializationState = .notInitialized
    
    /// 是否有内容可以生成
    @Published public private(set) var hasContent: Bool = false
    
    /// 最近一次推理的性能指标
    @Published public private(set) var latestMetrics: MTMDInferenceMetrics?

    /// 是否为纯文本模型（影响 <think> 注入行为）
    public var isTextOnlyModel: Bool = false
    
    // MARK: - Private Properties
    
    /// MTMD 上下文指针
    private var context: OpaquePointer?
    
    /// 生成参数
    private var params: MTMDParams?
    
    /// 生成任务
    private var generationTask: Task<Void, Never>?
    
    /// 生成队列
    private let generationQueue = DispatchQueue(label: "com.mtmd.generation", qos: .userInitiated)
    
    /// 线程锁
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    public init() {
        print("MTMDWrapper: 初始化")
    }
    
    deinit {
        // 在 deinit 中同步清理资源
        generationTask?.cancel()
        generationTask = nil
        
        // 清理资源
        if let ctx = context {
            mb_mtmd_free(ctx)
            context = nil
        }
        
        print("MTMDWrapper: 析构函数清理完成")
    }
    
    // MARK: - Public Methods
    
    /// 初始化 MTMD 上下文
    /// - Parameter params: 初始化参数
    public func initialize(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }
        
        updateInitializationState(.initializing)
        
        // 在后台线程执行初始化
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cParams = params.toCParams()
                // 路径在新 bridge 里作为 mb_mtmd_init 的独立参数传，
                // 避免把 const char * 字段塞进结构体后 Swift 闭包外指针失效。
                let ctx = params.modelPath.withCString { modelCStr in
                    params.mmprojPath.withCString { mmprojCStr in
                        mb_mtmd_init(modelCStr, mmprojCStr, &cParams)
                    }
                }

                if ctx == nil {
                    continuation.resume(throwing: MTMDError.initializationFailed("无法创建 MTMD 上下文"))
                    return
                }
                
                // 回到主线程更新状态
                Task { @MainActor in
                    self.context = ctx
                    self.params = params
                    self.initializationState = .initialized
                    print("MTMDWrapper: 初始化成功")
                    continuation.resume()
                }
            }
        }
    }

    /// 初始化纯文本模型（无 mmproj / 视觉模块）
    public func initializeTextOnly(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }

        updateInitializationState(.initializing)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cParams = params.toCParams()
                let ctx = params.modelPath.withCString { modelCStr in
                    mb_mtmd_init_text_only(modelCStr, &cParams)
                }

                if ctx == nil {
                    continuation.resume(throwing: MTMDError.initializationFailed("无法创建纯文本模型上下文"))
                    return
                }

                Task { @MainActor in
                    self.context = ctx
                    self.params = params
                    self.isTextOnlyModel = true
                    self.initializationState = .initialized
                    print("MTMDWrapper: 纯文本模型初始化成功")
                    continuation.resume()
                }
            }
        }
    }

    /// addImageInBackground / addFrameInBackground 默认超时（秒）。
    ///
    /// MiniCPM-V 4.6 + 9 切片 + 首次 ANE 编译，最坏路径在老设备上也通常 < 60s。
    /// 给 180s 是为了"宁可慢但保住功能"，超过这个时间几乎一定是 ANE driver
    /// 卡住或者磁盘 IO 卡住，应当上报失败让 UI 兜底。
    public static let defaultPrefillTimeoutSeconds: TimeInterval = 180

    /// 在后台线程中添加图片（非 @MainActor 版本）
    /// - Parameters:
    ///   - imagePath: 图片路径
    ///   - timeoutSeconds: 等待 mb_mtmd_prefill_image 的最长时间。超时即抛
    ///     `MTMDError.timeout`，让上层（cell 进度条 / "预处理耗时" 文本）能
    ///     走兜底分支，而不是永远卡在没有耗时的状态。
    ///     注意：由于 C++ 同步 API 没法被中断，超时后底层调用仍会在后台跑完，
    ///     但 Swift 这边已经放手，UI 不再被它绑住。
    public func addImageInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addImageInBackground timed out after \(Int(timeoutSeconds))s (image=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { mb_mtmd_prefill_image(ctx, $0) }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addImageInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }

    public func addFrameInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addFrameInBackground timed out after \(Int(timeoutSeconds))s (frame=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { mb_mtmd_prefill_frame(ctx, $0) }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addFrameInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }
    
    /// 在后台线程中添加文本（非 @MainActor 版本）
    /// - Parameters:
    ///   - text: 文本内容
    ///   - role: 角色（user/assistant）
    public func addTextInBackground(_ text: String, role: String = "user") async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }
        
        // 在后台线程执行 C 函数调用
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = text.withCString { textCStr in
                    role.withCString { roleCStr in
                        mb_mtmd_prefill_text(ctx, textCStr, roleCStr)
                    }
                }

                if result != 0 {
                    let errorMessage = mb_mtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    continuation.resume(throwing: MTMDError.textAddFailed(error))
                } else {
                    // 回到主线程更新状态
                    Task { @MainActor in
                        self.hasContent = true
                        print("MTMDWrapper: 文本添加成功（后台线程）: \(text)")
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// 开始生成
    /// - Parameter earlyStopPredicate: 可选的提前早停谓词。输入为当前已累加的输出文本，返回 true 则提前结束推理。
    public func startGeneration(earlyStopPredicate: (@Sendable (String) -> Bool)? = nil) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard hasContent else {
            throw MTMDError.noContentToGenerate
        }
        
        // 允许在空闲或已完成状态下重新开始生成
        guard generationState == .idle || generationState == .completed else {
            throw MTMDError.generationInProgress
        }
        
        updateGenerationState(.generating)

        // 取消之前的生成任务
        generationTask?.cancel()

        // 创建新的生成任务并 await 其完成：让 recognize 在 startGeneration 返回时
        // wrapper.fullOutput 已填好，从而能正确 parseResult。
        // 重构后密集的 C++ 原生推理循环完全在后台任务中全速连续运行，彻底移除了逐 token 的 Task.sleep 人工延迟，
        // 并以 20fps 节流向主线程广播更新。
        let task = Task {
            await performGeneration(earlyStopPredicate: earlyStopPredicate)
        }
        generationTask = task
        await task.value
    }
    
    /// 停止生成
    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        // 只有在当前状态不是 completed 时才重置为 idle
        if generationState != .completed {
            updateGenerationState(.completed)
        }
        print("MTMDWrapper: 生成已停止")
    }
    
    /// Set the model version so the C bridge can pick the correct prompt template.
    /// - Parameter version: 26=V2.6, 40=V4.0, 46=V4.6, 5=MiniCPM5
    public func setModelVersion(_ version: Int) {
        guard let ctx = context else { return }
        mb_mtmd_set_model_version(ctx, Int32(version))
    }

    /// 重置上下文
    public func reset() async {
        stopGeneration()
        
        // 清理资源
        if let ctx = context {
            mb_mtmd_free(ctx)
            context = nil
        }
        
        // 重置状态
        initializationState = .notInitialized
        generationState = .idle
        currentToken = .empty
        fullOutput = ""
        hasContent = false
        isTextOnlyModel = false
        latestMetrics = nil
        params = nil
        
        print("MTMDWrapper: 上下文已重置")
    }

    /// 仅清 KV cache + n_past=0，**保留** mtmd_context / llama_context / sampler 不重建。
    ///
    /// 用途：开启一段独立的 prefill turn（例如视频抽帧、跨场景切换），跟 Python
    /// 端 minicpm-v 的 `model.chat(msgs=[...], ...)` 行为对齐——每次 chat 调用都从
    /// 干净的 KV 开始，不带前序对话历史。这样可以避免：
    ///   1. n_ctx 溢出：长对话累积 + 视频抽帧 80+ token/帧 很容易顶到 n_ctx=8192，
    ///      触发 llama_decode 失败；MiniCPM-V 4.6 的 hybrid SSM+Attn 模型上，单
    ///      chunk 失败后 KV 无法 partial truncate（SSM 不支持），整 ctx 就废了；
    ///   2. M-RoPE 一致性裂缝：同上 root cause 的连环失败。
    ///
    /// 比起 `reset()` 这种"销毁 ctx + 重新 init"的重操作，这里只是 O(1) 调
    /// `llama_memory_seq_rm(seq=0, p0=0, p1=-1)`，毫秒级，不需要重新 load 模型。
    public func clearKVCacheForNewTurn() {
        guard let ctx = context else { return }
        let ok = mb_mtmd_clean_kv_cache(ctx)
        print("MTMDWrapper: clearKVCacheForNewTurn -> \(ok)")
        // 同步 Swift 侧的"有内容"标志，避免 startGeneration 因为旧标志而尝试用空 KV 跑
        hasContent = false
    }
    
    /// 清理资源
    public func cleanup() async {
        await reset()
    }
    
    // MARK: - Private Methods
    
    /// 供后台生成循环节流回调主线程更新 UI 状态
    private func updateStreamingOutput(fullText: String, token: String, isEnd: Bool) {
        self.currentToken = MTMDToken(content: token, isEnd: isEnd)
        self.fullOutput = fullText
    }

    /// 执行全速非阻塞生成
    private func performGeneration(earlyStopPredicate: (@Sendable (String) -> Bool)?) async {
        guard let ctx = context else {
            updateGenerationState(.failed(.contextNotInitialized))
            return
        }

        let initialAccumulated: String = isTextOnlyModel ? "<think>\n" : ""
        fullOutput = initialAccumulated
        let predictionLimit = max(params?.nPredict ?? 64, 1)

        // 密集的 C 原生推理循环完全在后台运行，消除 MainActor 乒乓切换与 Task.sleep 延迟
        let result = await Task.detached(priority: .userInitiated) { [ctx, isTextOnlyModel, weak self] () -> (output: String, tokenCount: Int, duration: TimeInterval, earlyStopped: Bool, limitReached: Bool) in
            var accumulated = initialAccumulated
            var generatedTokenCount = 0
            var earlyStopped = false
            var limitReached = false
            let flushIntervalMs: TimeInterval = 0.050 // 20 fps
            var lastFlush: Date = .distantPast
            let startTime = Date()

            while !Task.isCancelled {
                // 原生推理单个 token
                let cToken = mb_mtmd_loop(ctx)
                let rawTokenString = cToken.token != nil ? String(cString: cToken.token!) : ""
                let isEnd = cToken.is_end

                // 立即释放 C 字符串
                if let tokenPtr = cToken.token {
                    mb_mtmd_string_free(tokenPtr)
                }

                var tokenString = rawTokenString
                if accumulated.isEmpty && tokenString == "\n" {
                    tokenString = ""
                }
                accumulated += tokenString
                if !isEnd {
                    generatedTokenCount += 1
                }

                if generatedTokenCount >= predictionLimit {
                    limitReached = true
                }

                // 检查早停条件（例如 JSON 已完整闭合）
                if !isEnd && !accumulated.isEmpty && (earlyStopPredicate?(accumulated) == true) {
                    earlyStopped = true
                }

                let now = Date()
                let shouldFlush = isEnd || limitReached || earlyStopped || (now.timeIntervalSince(lastFlush) >= flushIntervalMs)

                if shouldFlush {
                    let currentAcc = accumulated
                    let currentTok = tokenString
                    Task { @MainActor in
                        self?.updateStreamingOutput(fullText: currentAcc, token: currentTok, isEnd: isEnd || limitReached || earlyStopped)
                    }
                    lastFlush = now
                }

                if isEnd || limitReached || earlyStopped {
                    break
                }
            }

            let duration = max(Date().timeIntervalSince(startTime), 0.001)
            return (accumulated, generatedTokenCount, duration, earlyStopped, limitReached)
        }.value

        let tokensPerSec = Double(result.tokenCount) / result.duration
        let metrics = MTMDInferenceMetrics(
            decodeDuration: result.duration,
            generatedTokenCount: result.tokenCount,
            tokensPerSecond: tokensPerSec,
            earlyStopped: result.earlyStopped
        )
        self.latestMetrics = metrics
        self.fullOutput = result.output
        self.currentToken = MTMDToken(content: "", isEnd: true)
        self.updateGenerationState(.completed)
        self.generationTask = nil

        if result.earlyStopped {
            print("MTMDWrapper: 提前早停命中，耗时 \(String(format: "%.2f", result.duration))s, 生成 \(result.tokenCount) tokens (\(String(format: "%.1f", tokensPerSec)) tok/s)")
        } else if result.limitReached {
            print("MTMDWrapper: 达到输出上限 \(predictionLimit) token，耗时 \(String(format: "%.2f", result.duration))s")
        } else {
            print("MTMDWrapper: 生成完成，耗时 \(String(format: "%.2f", result.duration))s, \(result.tokenCount) tokens (\(String(format: "%.1f", tokensPerSec)) tok/s)")
        }
    }
    
    /// 给同步阻塞型 C 调用包一层 watchdog 超时。
    ///
    /// 这里的 contract：
    /// - `body` 一定要在某个后台线程上启动 C 调用，并把它的成功 / 失败用
    ///   `resumeOnce` 上报。`resumeOnce` 自带 idempotency，多次调用只生效首次。
    /// - watchdog 在 `timeoutSeconds` 后会再调 `resumeOnce(.failure(.timeout))`，
    ///   如果 body 的 success / failure 已经先到，watchdog 是 no-op。
    /// - 反过来如果 watchdog 先到，body 后到的 resumeOnce 是 no-op，但 C 调用
    ///   仍会在后台跑完。这是有意为之 —— 我们没法中断同步 C API，但至少不
    ///   让 UI 永远等。下一次进入会先 `mb_mtmd_clean_kv_cache` / reset，
    ///   被孤儿化的那次推理对状态没有持续污染。
    private func runWithWatchdog(
        timeoutSeconds: TimeInterval,
        timeoutMessage: String,
        body: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        // 把 idempotent 的 resume 状态寄存到一个引用类型上（class wrapper），
        // 避免在 @escaping 闭包之间共享 var 导致的 Sendable 警告。
        final class ResumeState {
            let lock = NSLock()
            var didResume = false
        }
        let state = ResumeState()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                state.lock.lock()
                if state.didResume {
                    state.lock.unlock()
                    return
                }
                state.didResume = true
                state.lock.unlock()

                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            body(resumeOnce)

            // watchdog：用 utility QoS 的全局队列，避免抢占 userInitiated。
            // 时机点过了就触发 timeout，但如果 worker 已经先 resume，
            // resumeOnce 会自动 no-op。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeOnce(.failure(MTMDError.timeout(timeoutMessage)))
            }
        }
    }

    /// 更新初始化状态
    private func updateInitializationState(_ state: MTMDInitializationState) {
        initializationState = state
    }
    
    /// 更新生成状态
    private func updateGenerationState(_ state: MTMDGenerationState) {
        generationState = state
    }
}
