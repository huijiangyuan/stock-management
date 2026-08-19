import Foundation

enum AppFormatters {
    /// 标准年月日数字日期：yyyy-MM-dd（如 2026-08-19），强制中文公历，杜绝英文月份
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    /// 中文年月日汉字日期：yyyy年MM月dd日（如 2026年08月19日）
    static let chineseDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年MM月dd日"
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    /// 标准日期时间：yyyy-MM-dd HH:mm（如 2026-08-19 12:10）
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f
    }()

    static func fmt(_ value: Double) -> String {
        number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return self.date.string(from: date)
    }

    static func formatDateTime(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return self.dateTime.string(from: date)
    }

    static func formatChineseDate(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return self.chineseDate.string(from: date)
    }

    /// Float32 数组 <-> Data（特征向量占位存储，后续接入 sqlite-vec）
    static func toData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func toFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
