//
//  AppLogger.swift
//  库存管理 App · 运行诊断日志与全局 Toast 系统
//
//  负责：全局捕获并记录 AI 引擎、相机会话、存储持久化、网络 API 等模块的显式异常；
//  提供端侧可直观查阅的实时 Log 队列与物理落盘日志；
//  当抛出 Error 级日志时，自动触发 Toast 弹窗展现于 UI，严禁静默掩盖异常。
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    struct LogItem: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: Category
        let message: String
        let details: String?

        enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"

            var color: Color {
                switch self {
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                }
            }

            var icon: String {
                switch self {
                case .info: return "info.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .error: return "xmark.octagon.fill"
                }
            }
        }

        enum Category: String, CaseIterable {
            case system = "系统"
            case camera = "相机"
            case ai = "AI引擎"
            case store = "数据库"
            case network = "网络"
        }
    }

    private(set) var logs: [LogItem] = []
    private let maxLogsCount = 500
    private var logFileURL: URL?

    private init() {
        setupFileLog()
        log(level: .info, category: .system, message: "AppLogger 诊断日志初始化就绪")
    }

    private func setupFileLog() {
        let fm = FileManager.default
        if let doc = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = doc.appendingPathComponent("logs", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            logFileURL = dir.appendingPathComponent("app_runtime.log")
        }
    }

    func log(level: LogItem.Level, category: LogItem.Category, message: String, details: String? = nil) {
        let item = LogItem(timestamp: Date(), level: level, category: category, message: message, details: details)
        logs.insert(item, at: 0)
        if logs.count > maxLogsCount {
            logs.removeLast()
        }

        // 同步落盘
        let timeStr = ISO8601DateFormatter().string(from: item.timestamp)
        let line = "[\(timeStr)] [\(level.rawValue)] [\(category.rawValue)] \(message)\(details != nil ? " | Details: \(details!)" : "")\n"
        if let url = logFileURL {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        // 遇到 ERROR 自动通过 Toast 暴露到界面
        if level == .error {
            ToastManager.shared.show(message: message, details: details, tone: .error)
        } else if level == .warning {
            ToastManager.shared.show(message: message, details: details, tone: .warning)
        }
    }

    func clear() {
        logs.removeAll()
        if let url = logFileURL {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportLogsString() -> String {
        logs.map { item in
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
            return "[\(df.string(from: item.timestamp))] [\(item.level.rawValue)] [\(item.category.rawValue)] \(item.message)\(item.details.map { "\n  ➜ \($0)" } ?? "")"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Toast 全局提示管理器

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    struct ToastItem: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let details: String?
        let tone: Tone
        let timestamp: Date

        enum Tone {
            case info, warning, error, success

            var color: Color {
                switch self {
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                case .success: return .green
                }
            }

            var icon: String {
                switch self {
                case .info: return "info.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .error: return "exclamationmark.octagon.fill"
                case .success: return "checkmark.circle.fill"
                }
            }
        }
    }

    var currentToast: ToastItem? = nil
    private var timerTask: Task<Void, Never>? = nil

    func show(message: String, details: String? = nil, tone: ToastItem.Tone = .info, duration: TimeInterval = 4.0) {
        timerTask?.cancel()
        let toast = ToastItem(message: message, details: details, tone: tone, timestamp: Date())
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentToast = toast
        }

        timerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.3)) {
                    if self.currentToast == toast {
                        self.currentToast = nil
                    }
                }
            }
        }
    }

    func dismiss() {
        timerTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            currentToast = nil
        }
    }
}

// MARK: - Toast 全局浮层视图修饰器

struct ToastOverlayModifier: ViewModifier {
    @State private var toastMgr = ToastManager.shared

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if let toast = toastMgr.currentToast {
                VStack {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: toast.tone.icon)
                            .font(.title3)
                            .foregroundColor(toast.tone.color)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(toast.message)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            if let det = toast.details, !det.isEmpty {
                                Text(det)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer(minLength: 4)
                        Button {
                            toastMgr.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                                .padding(6)
                        }
                    }
                    .padding(12)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(toast.tone.color.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(999)
            }
        }
    }
}

extension View {
    func withToastOverlay() -> some View {
        self.modifier(ToastOverlayModifier())
    }
}
