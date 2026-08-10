//
//  AppVersion.swift
//  库存管理 App · 编译版本与 Commit 标识
//
//  用于在端侧界面（设置页、首页、排障日志）最显著位置暴露出确切的 App 版本号、
//  Build 时间戳与 Git Commit 简码，破除缓存疑虑，方便用户快速核验最新构建。
//

import Foundation

enum AppVersion {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let build = info["CFBundleVersion"] as? String ?? "0"
    static let buildDate = info["StockBuildDate"] as? String ?? "unknown"
    static let commit = info["StockGitCommit"] as? String ?? "local"
    static let shortCommit = String(commit.prefix(7))

    static var displayString: String {
        "v\(version) · Build \(build) · \(buildDate) · \(shortCommit)"
    }

    static var fullDetailString: String {
        "StockManager v\(version)\nBuild: \(build)\nDate: \(buildDate)\nCommit: \(commit)\nEngine: MobileCLIP + MiniCPM-V 4.6 + Accelerate vDSP"
    }
}
