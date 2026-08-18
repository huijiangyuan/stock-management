import Foundation
import UIKit

/// 云端 VLM 返回的原始结构化字段
struct VisionRawResult {
    var skuName: String?
    var unitName: String?
    var categoryName: String?
    var shelfLifeDays: Int?
    var barcode: String?
    var productionDate: String?
    var expirationDate: String?
    var confidence: Double
}

enum VisionError: LocalizedError {
    case httpError(statusCode: Int, message: String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg):
            return "云端 VLM 请求失败 (HTTP \(code)): \(msg)"
        case .parseError:
            return "解析云端 VLM 响应失败"
        }
    }
}

/// 视觉识别服务商协议（DashScope / Anthropic 可插拔）
protocol CloudVisionProvider {
    func recognize(image: Data, prompt: String) async throws -> VisionRawResult
}

/// 把图片缩到最长边 <= 1024，控制上传体积与延迟（必须在主线程操作 UIImage）
func downscaleImage(_ data: Data, maxSide: CGFloat = 1024) -> Data {
    guard let img = UIImage(data: data) else { return data }
    let size = img.size
    let longest = max(size.width, size.height)
    guard longest > maxSide else { return data }
    let scale = maxSide / longest
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
    img.draw(in: CGRect(origin: .zero, size: newSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return resized?.jpegData(compressionQuality: 0.8) ?? data
}

/// 从模型文本里抽取首个 JSON 对象（兼容 ```json 代码块 / 裸 JSON）
func extractJSON(_ text: String) -> Data? {
    var s = text
    if let start = s.range(of: "```") {
        let after = s[start.upperBound...]
        if let end = after.range(of: "```") {
            s = String(after[..<end.lowerBound])
            if s.hasPrefix("json") { s = String(s.dropFirst(4)) }
        }
    }
    guard let objStart = s.firstIndex(of: "{"),
          let objEnd = s.lastIndex(of: "}") else { return nil }
    return String(s[objStart...objEnd]).data(using: .utf8)
}

private struct VisionRawResponse: Decodable {
    let sku_name: String?
    let name: String?
    let unit_name: String?
    let unit: String?
    let category: String?
    let category_name: String?
    let shelf_life_days: Int?
    let barcode: String?
    let production_date: String?
    let expiration_date: String?
    let confidence: Double?
}

extension CloudVisionProvider {
    /// 统一把服务商文本解析为 VisionRawResult
    func parse(_ text: String) -> VisionRawResult {
        guard let data = extractJSON(text),
              let resp = try? JSONDecoder().decode(VisionRawResponse.self, from: data) else {
            return VisionRawResult(skuName: nil, unitName: nil, categoryName: nil,
                                   shelfLifeDays: nil, barcode: nil,
                                   productionDate: nil, expirationDate: nil, confidence: 0)
        }
        let name = resp.sku_name ?? resp.name
        let unit = resp.unit_name ?? resp.unit
        let cat = resp.category_name ?? resp.category
        return VisionRawResult(
            skuName: name,
            unitName: unit,
            categoryName: cat,
            shelfLifeDays: resp.shelf_life_days,
            barcode: resp.barcode,
            productionDate: resp.production_date,
            expirationDate: resp.expiration_date,
            confidence: resp.confidence ?? 0.5
        )
    }
}

/// 阿里云 DashScope 通义千问视觉（数据驻留：中国境内）
struct DashScopeProvider: CloudVisionProvider {
    func recognize(image: Data, prompt: String) async throws -> VisionRawResult {
        let settings = VisionSettings.shared
        let key = settings.apiKey ?? ""
        let base = settings.baseURL ?? "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        let model = settings.modelName ?? "qwen-vl-max"
        let small = await MainActor.run { downscaleImage(image) }
        let b64 = small.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "input": ["messages": [[
                "role": "user",
                "content": [
                    ["image": "data:image/jpeg;base64,\(b64)"],
                    ["text": prompt]
                ]
            ]]],
            "parameters": ["result_format": "message"]
        ]
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw VisionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let output = json["output"] as? [String: Any],
           let choices = output["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] {
            if let arr = content as? [[String: Any]] {
                let texts = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return parse(texts)
            } else if let str = content as? String {
                return parse(str)
            }
        }
        return VisionRawResult(skuName: nil, unitName: nil, productionDate: nil,
                               expirationDate: nil, confidence: 0)
    }
}

/// Anthropic Claude 视觉（数据驻留：美国，触发出境合规）
struct AnthropicProvider: CloudVisionProvider {
    func recognize(image: Data, prompt: String) async throws -> VisionRawResult {
        let settings = VisionSettings.shared
        let key = settings.apiKey ?? ""
        let base = settings.baseURL ?? "https://api.anthropic.com/v1/messages"
        let model = settings.modelName ?? "claude-3-5-sonnet-20241022"
        let small = await MainActor.run { downscaleImage(image) }
        let b64 = small.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw VisionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return parse(texts)
        }
        return VisionRawResult(skuName: nil, unitName: nil, productionDate: nil,
                               expirationDate: nil, confidence: 0)
    }
}
