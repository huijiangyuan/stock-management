//
//  MTMDParams.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation

/// MTMD 参数配置
@frozen public struct MTMDParams: Sendable {

    /// 模型路径
    public let modelPath: String

    /// 多模态投影模型路径
    public let mmprojPath: String

    /// 预测长度
    public let nPredict: Int

    /// 上下文长度
    public let nCtx: Int

    /// 线程数
    public let nThreads: Int

    /// 温度参数
    public let temperature: Float

    /// 是否使用 GPU
    public let useGPU: Bool

    /// 多模态投影是否使用 GPU
    public let mmprojUseGPU: Bool

    /// 是否预热
    public let warmup: Bool

    /// llama_context 的 physical batch（n_ubatch）。0 = 使用 bridge 默认值。
    /// 端侧库存识别统一使用 128，优先压低原生工作缓冲峰值。
    public let nUbatch: Int

    /// 根据当前移动设备硬件动态评估的最佳推理 CPU 线程数。
    /// 移动端一般推荐 2~4 线程：在留出 UI/系统核的同时充分调用性能核（P-Core），避免过多能效核拖慢。
    public static var optimalThreadCount: Int {
        let count = ProcessInfo.processInfo.activeProcessorCount
        if count <= 2 { return max(1, count) }
        if count <= 4 { return 3 }
        return min(4, count - 1)
    }

    /// 初始化方法
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    ///   - nPredict: 输出 token 上限，默认 64；库存 JSON 已足够，避免异常长生成。
    ///   - nCtx: 上下文长度，默认 1536；单图库存识别不走视频上下文，降低 KV 峰值。
    ///   - nThreads: 线程数，默认根据设备动态评估最佳线程数（2~4）
    ///   - temperature: 温度参数，默认 0.7（对齐模型 generation_config.json：
    ///     do_sample=true, temperature=0.7, top_k=0, top_p=1.0, repetition_penalty=1.0；
    ///     top_k 与 top_p 由 MBMtmd.mm 内部统一设为禁用值，纯温度采样）
    ///   - useGPU: 是否使用 GPU，默认 false
    ///   - mmprojUseGPU: 多模态投影是否使用 GPU，默认 false
    ///   - warmup: 是否预热，默认 true
    public init(
        modelPath: String,
        mmprojPath: String,
        nPredict: Int = 64,
        nCtx: Int = 1536,
        nThreads: Int = MTMDParams.optimalThreadCount,
        temperature: Float = 0.7,
        useGPU: Bool = false,
        mmprojUseGPU: Bool = false,
        warmup: Bool = true,
        nUbatch: Int = 0
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.nPredict = nPredict
        self.nCtx = nCtx
        self.nThreads = nThreads
        self.temperature = temperature
        self.useGPU = useGPU
        self.mmprojUseGPU = mmprojUseGPU
        self.warmup = warmup
        self.nUbatch = nUbatch
    }

    /// 创建默认参数
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    /// - Returns: 默认参数配置
    public static func `default`(modelPath: String, mmprojPath: String) -> MTMDParams {
        return MTMDParams(
            modelPath: modelPath,
            mmprojPath: mmprojPath
        )
    }

    /// 转换为 native bridge 的 C 结构体（不含路径，路径作为 mb_mtmd_init 的独立参数传）。
    internal func toCParams() -> mb_mtmd_params {
        var params = mb_mtmd_params_default()
        params.n_predict             = Int32(nPredict)
        params.n_ctx                 = Int32(nCtx)
        params.n_ubatch              = Int32(nUbatch)
        params.n_threads             = Int32(nThreads)
        params.temperature           = temperature
        params.use_gpu               = useGPU
        params.mmproj_use_gpu        = mmprojUseGPU
        params.warmup                = warmup
        return params
    }
}
