//
//  OnDeviceSafety.swift
//  库存管理 App · MiniCPM-V 端侧推理内存准入
//

import Foundation
import os

enum OnDeviceInferencePhase: String, Equatable {
    case modelLoad
    case imageInference

    var title: String {
        switch self {
        case .modelLoad: return "模型加载"
        case .imageInference: return "图片推理"
        }
    }
}

struct OnDeviceMemoryAssessment: Equatable {
    let phase: OnDeviceInferencePhase
    let availableBytes: UInt64
    let minimumAvailableBytes: UInt64
    let physicalMemoryBytes: UInt64
    let recommendedDeviceMemoryBytes: UInt64
    let safe: Bool

    var diagnosticSummary: String {
        "phase=\(phase.rawValue), available=\(Self.format(availableBytes)), "
            + "required=\(Self.format(minimumAvailableBytes)), "
            + "physical=\(Self.format(physicalMemoryBytes)), "
            + "recommendedPhysical=\(Self.format(recommendedDeviceMemoryBytes))"
    }

    var reason: String {
        guard !safe else { return "" }
        if availableBytes == 0 {
            return "无法读取当前进程可用内存，已阻止 MiniCPM-V \(phase.title)，避免原生推理被系统强制终止。请重启 App 后重试。"
        }
        if physicalMemoryBytes < recommendedDeviceMemoryBytes {
            return "MiniCPM-V 4.6 官方建议设备内存至少 6 GB；当前约 \(Self.format(physicalMemoryBytes))，不满足端侧运行条件。"
        }
        let missing = minimumAvailableBytes > availableBytes ? minimumAvailableBytes - availableBytes : 0
        return "MiniCPM-V \(phase.title)内存不足：当前进程可用 \(Self.format(availableBytes))，"
            + "本阶段至少需要 \(Self.format(minimumAvailableBytes))，还差 \(Self.format(missing))。"
            + "请关闭其他 App、重启 LiveContainer 后重试；若仍不足，说明侧载容器内存上限低于模型需求。"
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

enum OnDeviceSafeEnvironment {
    /// OpenBMB 官方口径：MiniCPM-V 4.6 GGUF CPU 运行约占 2 GB，端侧设备建议至少 6 GB RAM。
    static let officialRuntimeBytes: UInt64 = 2_000_000_000
    static let recommendedDeviceMemoryBytes: UInt64 = 6_000_000_000

    /// 模型文件以 mmap 按需映射；2 GB 是运行期占用估算，不能当成「加载前必须空闲」的内存。
    /// 加载前只校验 App/原生初始化所需的真实安全余量。
    static let modelLoadMinimumAvailableBytes: UInt64 = 1_100_000_000
    /// 推理前仍需为单图视觉预处理、KV cache 与 C++ 临时缓冲保留额外余量。
    static let inferenceMinimumAvailableBytes: UInt64 = 1_250_000_000

    static func evaluate(
        phase: OnDeviceInferencePhase,
        availableMemory: UInt64 = UInt64(os_proc_available_memory()),
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> OnDeviceMemoryAssessment {
        let minimum = phase == .modelLoad
            ? modelLoadMinimumAvailableBytes
            : inferenceMinimumAvailableBytes
        let safe = availableMemory > 0
            && availableMemory >= minimum
            && physicalMemory >= recommendedDeviceMemoryBytes
        return OnDeviceMemoryAssessment(
            phase: phase,
            availableBytes: availableMemory,
            minimumAvailableBytes: minimum,
            physicalMemoryBytes: physicalMemory,
            recommendedDeviceMemoryBytes: recommendedDeviceMemoryBytes,
            safe: safe
        )
    }
}
