import Foundation
import Observation

/// AI 视觉识别配置（全局单例）。API Key 存 Keychain，其余偏好存 UserDefaults。
@Observable
final class VisionSettings {
    static let shared = VisionSettings()

    enum Provider: String, Codable {
        case dashscope = "dashscope"
        case anthropic = "anthropic"
    }

    /// 数据驻留地（合规告知用）：DashScope=中国境内，Anthropic=美国（出境）
    var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "vision_provider") ?? "") ?? .dashscope }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "vision_provider") }
    }

    /// 仅本地 / 不上云：开启后禁用云端，仅使用 MobileCLIP + MiniCPM-V。
    var localOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "vision_local_only") }
        set { UserDefaults.standard.set(newValue, forKey: "vision_local_only") }
    }

    /// 云端 VLM 是否已可用（未开 localOnly 且已配置 API Key）
    var cloudReady: Bool {
        !localOnly && (apiKey?.isEmpty == false)
    }

    var modelName: String? {
        get { UserDefaults.standard.string(forKey: "vision_model") }
        set { UserDefaults.standard.set(newValue, forKey: "vision_model") }
    }

    var baseURL: String? {
        get { UserDefaults.standard.string(forKey: "vision_base_url") }
        set { UserDefaults.standard.set(newValue, forKey: "vision_base_url") }
    }

    /// API Key 存 Keychain（不进 UserDefaults）
    var apiKey: String? {
        get { KeychainHelper.read("vision_api_key") }
        set {
            if let v = newValue, !v.isEmpty { KeychainHelper.save(v, forKey: "vision_api_key") }
            else { KeychainHelper.delete("vision_api_key") }
        }
    }

    /// 是否触及数据出境（选 Anthropic 即数据传美国）
    var isCrossBorder: Bool { provider == .anthropic }
}
