//
//  OnDeviceSafety.swift
//  库存管理 App · 端侧大模型运行环境"事前准入"护栏
//
//  端侧引擎已强制 CPU-only 模式（useGPU=false → n_gpu_layers=0），
//  完全绕开 Metal 后端，因此 LiveContainer / SideStore 等侧载环境
//  均不会触发 Metal 原生崩溃。护栏仅保留内存检查作为安全网。
//

import Foundation
import os   // os_proc_available_memory()

enum OnDeviceSafeEnvironment {

    /// 评估当前环境是否可安全运行端侧推理（CPU-only 模式）。
    /// - Returns: `(safe, reason)`。`safe == false` 时 `reason` 为面向用户的引导文案。
    static func evaluate() -> (safe: Bool, reason: String) {
        // CPU-only 模式不依赖 Metal/GPU，LiveContainer、SideStore 等侧载环境均可安全运行。
        // 唯一需要检查的是可用内存：Q4_K_M 模型 CPU 推理需要 ~1.2GB 连续内存。
        let avail = os_proc_available_memory()
        if avail > 0 && avail < 1_200_000_000 {
            return (false, "可用内存不足（<1.2GB），端侧推理可能 OOM，请关闭其他应用后重试。")
        }

        return (true, "")
    }
}
