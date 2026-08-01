//
//  OnDeviceSafety.swift
//  库存管理 App · 端侧大模型运行环境"事前准入"护栏
//
//  为什么是事前而非事后：llama.cpp / Metal 后端的初始化与推理在异常环境下会
//  触发原生崩溃（EXC_BAD_ACCESS / SIGABRT），这类崩溃 Swift 的 do/catch 完全
//  抓不住。因此无法在崩溃后"补救"，只能在调用 MTMDWrapper.initialize /
// recognize 之前就判定环境是否安全；不安全则根本不进入 C 代码。
//

import Foundation
import Metal
import os   // os_proc_available_memory()

enum OnDeviceSafeEnvironment {

    /// 评估当前环境是否可安全运行端侧推理。
    /// - Returns: `(safe, reason)`。`safe == false` 时 `reason` 为面向用户的引导文案。
    static func evaluate() -> (safe: Bool, reason: String) {
        // 1) LiveContainer 侧载：检测其专属 LC_ 环境变量。无论 JIT 是否开启，
        //    其 GPU / 内存沙箱都可能让 llama.cpp 的 Metal 后端原生崩溃。
        if getenv("LC_HOME_PATH") != nil ||
           getenv("LC_GLOBAL_TWEAKS_FOLDER") != nil ||
           getenv("LiveContainer") != nil {
            return (false, "当前为 LiveContainer 侧载环境，端侧大模型（Metal 后端）会原生崩溃，已禁用。请改用 SideStore 全屏重签，或在「设置 → 端侧模型管理」配置云端 VLM。")
        }

        // 2) 无 Metal GPU / Metal 设备不可用
        if MTLCreateSystemDefaultDevice() == nil {
            return (false, "当前设备无可用 Metal GPU，端侧推理不可用，请配置云端 VLM。")
        }

        // 3) 可用内存过低：Metal compute buffer 需要连续大块内存，OOM 即崩。
        let avail = os_proc_available_memory()
        if avail > 0 && avail < 1_200_000_000 {
            return (false, "可用内存不足（<1.2GB），端侧推理可能 OOM 崩溃，已禁用，请配置云端 VLM。")
        }

        return (true, "")
    }
}
