import CoreML
import Foundation
import Vision

struct ImageEmbedding: Sendable, Equatable {
    let values: [Float]
    let modelVersion: String

    var dimension: Int { values.count }
}

protocol ImageEmbeddingProviding {
    func embed(imageData: Data) async throws -> ImageEmbedding
}

/// Apple MobileCLIP-S0 图片编码器。模型只加载一次，并在独立 actor 中串行执行，避免与 VLM 抢占内存。
actor MobileCLIPEmbeddingEngine: ImageEmbeddingProviding {
    enum EmbeddingError: LocalizedError {
        case modelResourceMissing
        case featureOutputMissing

        var errorDescription: String? {
            switch self {
            case .modelResourceMissing:
                return "应用包缺少 MobileCLIP-S0 模型资源"
            case .featureOutputMissing:
                return "MobileCLIP-S0 未返回图片向量"
            }
        }
    }

    static let modelVersion = "apple-mobileclip-s0-coreml-3e0a7bfb"

    private var visionModel: VNCoreMLModel?

    func embed(imageData: Data) async throws -> ImageEmbedding {
        let model = try loadModelIfNeeded()
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(data: imageData, orientation: .up)
        try handler.perform([request])

        guard let observation = request.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
              let multiArray = observation.featureValue.multiArrayValue else {
            throw EmbeddingError.featureOutputMissing
        }

        let values = (0..<multiArray.count).map { multiArray[$0].floatValue }
        return ImageEmbedding(
            values: try LocalFeatureEngine.normalized(values),
            modelVersion: Self.modelVersion
        )
    }

    private func loadModelIfNeeded() throws -> VNCoreMLModel {
        if let visionModel { return visionModel }
        guard let url = Bundle.main.url(forResource: "mobileclip_s0_image", withExtension: "mlmodelc") else {
            throw EmbeddingError.modelResourceMissing
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let wrapped = try VNCoreMLModel(for: model)
        visionModel = wrapped
        return wrapped
    }
}
