# AI Camera Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 LiveContainer 中稳定实现 NextLevel 拍照、MobileCLIP 图像向量 Top-3 检索、MiniCPM-V 低相似度兜底和结构化结果展示。

**Architecture:** 使用 NextLevel 管理相机生命周期，以一次性静态照片替代逐帧 JPEG；用 Core ML MobileCLIP-S0 生成视觉向量并通过 SwiftData + Accelerate 检索；由单一识别管线串行编排相机释放、向量检索和 MiniCPM-V。SwiftUI 只观察显式状态，不再通过固定延时串接 Sheet。

**Tech Stack:** Swift 6、SwiftUI、SwiftData、AVFoundation/NextLevel 0.19.1、Vision/Core ML、MobileCLIP-S0、Accelerate、OpenBMB MiniCPM-V-Apps/llama.cpp-omni、XCTest、XcodeGen。

---

## 文件结构

- `ios-app/Vendor/NextLevel/`：固定版本的 NextLevel 本地 Swift Package 与 MIT 许可证。
- `ios-app/StockInventoryApp/Resources/Models/mobileclip_s0_image.mlpackage/`：Apple 官方 Core ML 图像编码器。
- `ios-app/StockInventoryApp/Resources/Licenses/`：NextLevel 和 MobileCLIP 许可文本。
- `ios-app/StockInventoryApp/Camera/CameraCaptureService.swift`：相机会话、拍照和停止状态。
- `ios-app/StockInventoryApp/Camera/NextLevelCameraView.swift`：SwiftUI 预览与拍照 UI。
- `ios-app/StockInventoryApp/Recognition/CapturedImageProcessor.swift`：单次图像方向/尺寸/JPEG 归一化。
- `ios-app/StockInventoryApp/Recognition/ImageEmbeddingEngine.swift`：动态 Core ML 模型加载与向量生成。
- `ios-app/StockInventoryApp/Recognition/FeatureRepository.swift`：视觉样本写入与 Top-3 检索。
- `ios-app/StockInventoryApp/Recognition/VisionRecognitionPipeline.swift`：串行状态机和阈值决策。
- `ios-app/StockInventoryApp/Recognition/RecognitionSessionModel.swift`：SwiftUI 可观察会话状态。
- `ios-app/StockInventoryApp/Engine/RecognitionEngine.swift`：统一结果、候选、来源和失败类型。
- `ios-app/StockInventoryApp/Views/AIRecognitionResultView.swift`：Top-3 和 VLM 结果展示。
- `ios-app/StockInventoryAppTests/`：图片、向量、检索、管线和 VLM 解析测试。
- `ios-app/project.yml`：本地包、资源、测试 target 和 scheme。
- `.github/workflows/build-ios-ipa.yml`：测试、Release archive 和资产断言。

### Task 1: 建立测试 target 与向量安全编解码

**Files:**
- Modify: `ios-app/project.yml`
- Modify: `ios-app/StockInventoryApp/Engine/LocalFeatureEngine.swift`
- Create: `ios-app/StockInventoryAppTests/LocalFeatureEngineTests.swift`

- [ ] **Step 1: 在 `project.yml` 添加 XCTest target**

```yaml
  StockInventoryAppTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: StockInventoryAppTests
    dependencies:
      - target: StockInventoryApp
schemes:
  StockInventoryApp:
    test:
      targets:
        - StockInventoryAppTests
```

- [ ] **Step 2: 写失败测试，约束 Float32 解码、非有限值和 Top-K 排序**

```swift
import XCTest
@testable import StockInventoryApp

final class LocalFeatureEngineTests: XCTestCase {
    func testDecodeRejectsMisalignedData() {
        XCTAssertThrowsError(try LocalFeatureEngine.decodeVector(Data([0, 1, 2])))
    }

    func testNormalizeRejectsNonFiniteAndZeroVectors() {
        XCTAssertThrowsError(try LocalFeatureEngine.normalized([.nan, 1]))
        XCTAssertThrowsError(try LocalFeatureEngine.normalized([0, 0]))
    }

    func testCosineSimilarityRanksNearestVectorFirst() throws {
        let query = try LocalFeatureEngine.normalized([1, 0])
        let exact = try LocalFeatureEngine.normalized([1, 0])
        let other = try LocalFeatureEngine.normalized([0, 1])
        XCTAssertGreaterThan(LocalFeatureEngine.cosineSimilarity(query, exact),
                             LocalFeatureEngine.cosineSimilarity(query, other))
    }
}
```

- [ ] **Step 3: 生成工程并运行失败测试**

Run: `cd ios-app && xcodegen generate && xcodebuild test -project StockInventoryApp.xcodeproj -scheme StockInventoryApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:StockInventoryAppTests/LocalFeatureEngineTests`

Expected: FAIL，提示 `decodeVector`、`normalized` 尚不存在。

- [ ] **Step 4: 最小实现安全向量 API**

```swift
enum VectorError: Error, Equatable {
    case invalidByteCount
    case empty
    case nonFinite
    case zeroNorm
}

static func decodeVector(_ data: Data) throws -> [Float] {
    guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw VectorError.invalidByteCount
    }
    let result = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard !result.isEmpty else { throw VectorError.empty }
    guard result.allSatisfy(\.isFinite) else { throw VectorError.nonFinite }
    return result
}

static func normalized(_ vector: [Float]) throws -> [Float] {
    guard !vector.isEmpty else { throw VectorError.empty }
    guard vector.allSatisfy(\.isFinite) else { throw VectorError.nonFinite }
    var sum: Float = 0
    vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
    guard sum > 0 else { throw VectorError.zeroNorm }
    var scale = 1 / sqrt(sum)
    var output = [Float](repeating: 0, count: vector.count)
    vDSP_vsmul(vector, 1, &scale, &output, 1, vDSP_Length(vector.count))
    return output
}
```

- [ ] **Step 5: 运行测试并提交**

Run: 同 Step 3。

Expected: PASS。

Commit: `test(ai): add vector safety regression coverage`

### Task 2: 实现单次图片归一化

**Files:**
- Create: `ios-app/StockInventoryApp/Recognition/CapturedImageProcessor.swift`
- Create: `ios-app/StockInventoryAppTests/CapturedImageProcessorTests.swift`

- [ ] **Step 1: 写无效数据和最长边限制测试**

```swift
final class CapturedImageProcessorTests: XCTestCase {
    func testRejectsInvalidImageData() {
        XCTAssertThrowsError(try CapturedImageProcessor().prepare(Data([1, 2, 3])))
    }

    func testPreparedImageDoesNotExceedConfiguredSide() throws {
        let input = TestImageFactory.jpeg(width: 1600, height: 1200)
        let result = try CapturedImageProcessor(maxPixelSize: 1024).prepare(input)
        XCTAssertLessThanOrEqual(max(result.pixelWidth, result.pixelHeight), 1024)
        XCTAssertFalse(result.jpegData.isEmpty)
    }
}
```

- [ ] **Step 2: 运行并确认 RED**

Run: `cd ios-app && xcodebuild test -project StockInventoryApp.xcodeproj -scheme StockInventoryApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:StockInventoryAppTests/CapturedImageProcessorTests`

Expected: FAIL，类型不存在。

- [ ] **Step 3: 用 ImageIO 实现一次性缩略图和明确错误**

```swift
struct PreparedImage: Sendable {
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

struct CapturedImageProcessor {
    let maxPixelSize: Int

    init(maxPixelSize: Int = 1024) { self.maxPixelSize = maxPixelSize }

    func prepare(_ data: Data) throws -> PreparedImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ImagePreparationError.invalidData
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82) else {
                throw ImagePreparationError.encodingFailed
            }
            return PreparedImage(jpegData: jpeg, pixelWidth: image.width, pixelHeight: image.height)
        }
    }
}
```

- [ ] **Step 4: 运行测试并提交**

Expected: PASS。

Commit: `feat(camera): add single-pass captured image processing`

### Task 3: 接入 MobileCLIP-S0 并完成视觉样本仓库

**Files:**
- Create: `ios-app/StockInventoryApp/Resources/Models/mobileclip_s0_image.mlpackage/**`
- Create: `ios-app/StockInventoryApp/Resources/Licenses/MobileCLIP-LICENSE.txt`
- Create: `ios-app/StockInventoryApp/Recognition/ImageEmbeddingEngine.swift`
- Create: `ios-app/StockInventoryApp/Recognition/FeatureRepository.swift`
- Modify: `ios-app/StockInventoryApp/Models/FeatureSample.swift`
- Create: `ios-app/StockInventoryAppTests/FeatureRepositoryTests.swift`

- [ ] **Step 1: 下载并校验 Apple 官方 S0 image mlpackage**

下载固定 revision `3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947` 的 `mobileclip_s0_image.mlpackage` 三个文件；权重 `weight.bin` 的 linked SHA-256 为 `87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6`，大小 `22,717,696` 字节。若校验不一致立即失败。

- [ ] **Step 2: 写仓库过滤和 Top-3 失败测试**

```swift
func testSearchFiltersDifferentModelAndSortsTopThree() throws {
    let repository = FeatureRepository(context: context)
    try repository.insertFixture(vector: [1, 0], modelVersion: "mobileclip-s0@3e0a7bf", sku: skuA)
    try repository.insertFixture(vector: [0.9, 0.1], modelVersion: "mobileclip-s0@3e0a7bf", sku: skuB)
    try repository.insertFixture(vector: [0, 1], modelVersion: "other", sku: skuC)

    let matches = try repository.search(
        query: LocalFeatureEngine.normalized([1, 0]),
        modelVersion: "mobileclip-s0@3e0a7bf",
        limit: 3
    )

    XCTAssertEqual(matches.map(\.sample.sku?.skuCode), [skuA.skuCode, skuB.skuCode])
}
```

- [ ] **Step 3: 运行并确认 RED**

Expected: FAIL，`FeatureRepository` 和样本版本字段不存在。

- [ ] **Step 4: 扩展模型并实现仓库**

`FeatureSample` 新增非可选默认字段：

```swift
var visionModelVersion: String = ""
var visionVectorDimension: Int = 0
```

仓库保存前归一化向量，搜索时只比较版本和维度一致的样本；损坏样本记录 warning 后跳过，数据库读取失败直接抛错。

- [ ] **Step 5: 实现动态 MobileCLIP 引擎**

```swift
actor MobileCLIPEmbeddingEngine: ImageEmbeddingProviding {
    static let modelVersion = "mobileclip-s0@3e0a7bf"
    private var visionModel: VNCoreMLModel?

    func embed(imageData: Data) async throws -> ImageEmbedding {
        let model = try loadVisionModel()
        let observation = try await perform(model: model, imageData: imageData)
        let values = observation.featureValue.multiArrayValue?.copiedFloats ?? []
        return ImageEmbedding(
            values: try LocalFeatureEngine.normalized(values),
            modelVersion: Self.modelVersion
        )
    }
}

private extension MLMultiArray {
    var copiedFloats: [Float] {
        (0..<count).map { self[$0].floatValue }
    }
}
```

通过 `Bundle.main.url(forResource: "mobileclip_s0_image", withExtension: "mlmodelc")` 加载编译资源，使用 `VNCoreMLFeatureValueObservation` 读取第一个多数组输出；缺资源、无输出和非有限值分别抛出明确错误。

- [ ] **Step 6: 测试、生成工程并提交**

Expected: 仓库测试 PASS；XcodeGen 能识别 mlpackage 资源。

Commit: `feat(ai): add MobileCLIP visual embedding repository`

### Task 4: 用 NextLevel 替换逐帧 JPEG 相机

**Files:**
- Create: `ios-app/Vendor/NextLevel/**`
- Create: `ios-app/StockInventoryApp/Resources/Licenses/NextLevel-LICENSE.txt`
- Create: `ios-app/StockInventoryApp/Camera/CameraCaptureService.swift`
- Create: `ios-app/StockInventoryApp/Camera/NextLevelCameraView.swift`
- Modify: `ios-app/StockInventoryApp/Views/CameraCaptureView.swift`
- Delete: `ios-app/StockInventoryApp/Views/LuminaCameraView.swift`
- Modify: `ios-app/project.yml`
- Create: `ios-app/StockInventoryAppTests/CameraCaptureStateTests.swift`

- [ ] **Step 1: Vendor NextLevel 0.19.1 并配置本地包**

```yaml
packages:
  NextLevel:
    path: Vendor/NextLevel
targets:
  StockInventoryApp:
    dependencies:
      - package: NextLevel
```

保留上游 `Package.swift`、`Sources/NextLevel`、LICENSE；记录 tag 和 commit，不引入示例工程。

- [ ] **Step 2: 写相机状态失败测试**

```swift
func testCaptureCanFinishOnlyAfterSessionStopped() async throws {
    let driver = FakeCameraDriver()
    let service = CameraCaptureService(driver: driver)
    let task = Task { try await service.capturePhoto() }
    driver.yieldPhoto(Data([1]))
    await Task.yield()
    XCTAssertEqual(service.state, .stopping)
    driver.yieldStopped()
    XCTAssertEqual(try await task.value.data, Data([1]))
}
```

- [ ] **Step 3: 运行并确认 RED**

Expected: FAIL，服务和 driver 协议不存在。

- [ ] **Step 4: 实现相机驱动与服务**

```swift
protocol CameraDriving: AnyObject {
    var events: AsyncStream<CameraEvent> { get }
    func start() throws
    func capturePhoto()
    func stop()
}

@MainActor
final class CameraCaptureService: ObservableObject {
    @Published private(set) var state: CameraCaptureState = .idle
    func capturePhoto() async throws -> CapturedPhoto
}
```

NextLevel driver 仅配置 `.photo`、后置镜头和 JPEG；收到照片后立即请求 stop，只有 `didStop` 事件到达才恢复 continuation。所有 continuation 必须单次恢复；取消时停止会话并返回 `CancellationError`。

- [ ] **Step 5: 替换 UI 并删除旧相机**

`CameraCaptureView` 持有 `@StateObject CameraCaptureService`，使用 `NextLevel.shared.previewLayer` 展示预览。按钮禁用重复拍照；错误通过日志和 Toast 暴露。不再保留 `CameraVC` 和 `LuminaCameraViewController` 两套实现。

- [ ] **Step 6: 测试、检查无逐帧 JPEG 并提交**

Run: `rg -n "captureOutput|latestFrameData|300_000_000|Lumina" ios-app/StockInventoryApp`

Expected: 不再命中旧相机和固定 Sheet 延时。

Commit: `refactor(camera): replace frame JPEG capture with NextLevel photo flow`

### Task 5: 建立可测试的识别管线并强化 MiniCPM-V

**Files:**
- Modify: `ios-app/StockInventoryApp/Engine/RecognitionEngine.swift`
- Create: `ios-app/StockInventoryApp/Recognition/VisionRecognitionPipeline.swift`
- Create: `ios-app/StockInventoryApp/Recognition/RecognitionSessionModel.swift`
- Modify: `ios-app/StockInventoryApp/OnDevice/OnDeviceVisionEngine.swift`
- Modify: `ios-app/StockInventoryApp/OnDevice/MTMDWrapper.swift`
- Create: `ios-app/StockInventoryAppTests/VisionRecognitionPipelineTests.swift`
- Create: `ios-app/StockInventoryAppTests/OnDeviceResultParserTests.swift`

- [ ] **Step 1: 写阈值与 VLM 调用次数失败测试**

```swift
func testHighConfidenceMatchSkipsVLM() async throws {
    let sample = FeatureSample(unit: unit, sku: sku)
    repository.matches = [FeatureMatch(sample: sample, similarity: 0.91)]
    let result = try await pipeline.recognize(imageData: validJPEG)
    XCTAssertEqual(result.source, .visualMatch)
    XCTAssertEqual(vlm.callCount, 0)
}

func testNoMatchCallsVLMExactlyOnce() async throws {
    repository.matches = []
    _ = try await pipeline.recognize(imageData: validJPEG)
    XCTAssertEqual(vlm.callCount, 1)
}
```

- [ ] **Step 2: 写 JSON 解析失败测试**

覆盖纯 JSON、Markdown 代码围栏、缺字段、非法日期和非 JSON 文本；解析器返回明确 `parsed` 或 `unstructured`，不得吞错。

- [ ] **Step 3: 运行并确认 RED**

Expected: FAIL，新 API 不存在。

- [ ] **Step 4: 实现串行管线**

```swift
actor VisionRecognitionPipeline {
    static let automaticThreshold: Float = 0.85
    static let candidateThreshold: Float = 0.65

    func recognize(imageData: Data) async throws -> RecognitionOutcome {
        let id = UUID().uuidString
        let prepared = try imageProcessor.prepare(imageData)
        let embedding = try await embeddingEngine.embed(imageData: prepared.jpegData)
        let matches = try repository.search(query: embedding.values,
                                            modelVersion: embedding.modelVersion,
                                            limit: 3)
        if matches.first?.similarity ?? 0 >= Self.candidateThreshold {
            return .matches(id: id, image: prepared.jpegData, candidates: matches,
                            autoSelected: matches.first?.similarity ?? 0 >= Self.automaticThreshold)
        }
        return try await vlmFallback(id: id, image: prepared.jpegData, embedding: embedding)
    }
}
```

- [ ] **Step 5: 串行化原生 MTMD 调用并清理临时文件**

为 `recognize` 增加单任务门禁；识别结束、失败和取消时统一删除临时 JPEG。日志记录 recognitionID、阶段、耗时、输入大小与 `os_proc_available_memory()`。移除业务 View 的 `onAppear` 预热。

- [ ] **Step 6: 运行测试并提交**

Commit: `feat(ai): orchestrate vector-first recognition with VLM fallback`

### Task 6: 接入单据与 SKU 页面并展示 Top-3

**Files:**
- Modify: `ios-app/StockInventoryApp/Views/OrderCreateView.swift`
- Modify: `ios-app/StockInventoryApp/Views/SKUFormView.swift`
- Modify: `ios-app/StockInventoryApp/Views/AIRecognitionResultView.swift`
- Modify: `ios-app/StockInventoryApp/Diagnostics/AppLogger.swift`
- Create: `ios-app/StockInventoryAppTests/RecognitionSessionModelTests.swift`

- [ ] **Step 1: 写“旧任务不能覆盖新结果”的失败测试**

```swift
func testCancelledRecognitionCannotPublishStaleResult() async {
    let model = RecognitionSessionModel(pipeline: delayedPipeline)
    model.start(firstImage)
    model.start(secondImage)
    await delayedPipeline.finishFirst()
    XCTAssertNotEqual(model.result?.recognitionID, delayedPipeline.firstID)
}
```

- [ ] **Step 2: 实现会话模型并替换 Sheet 枚举**

相机仍是唯一 Sheet；相机完成后先置 `activeSheet = nil`，再由页面内 `RecognitionSessionModel` 显示进度 overlay 和结果 `fullScreenCover`/导航状态。禁止固定 sleep。

- [ ] **Step 3: 扩展结果页**

结果页新增候选卡：SKU、包装、相似度和选择按钮；同时显示 `视觉匹配` 或 `MiniCPM-V 兜底` 来源。失败页展示错误详情、重试、重拍和手动选择，不出现“未识别但成功”的绿色提示。

- [ ] **Step 4: 确认时保存真实视觉向量**

删除 `saveFeatureSample` 中的文本哈希伪视觉逻辑，统一调用 `FeatureRepository.save(imageData:embedding:sku:unit:ocrText:)`，保存失败必须阻止虚假“建库成功”。

- [ ] **Step 5: 修复现有编译缺陷并运行测试**

删除 `OrderCreateView` FIFO 覆盖分支中重复声明的 `let iso`。运行全部测试。

Commit: `feat(ai): integrate structured recognition results into inventory flow`

### Task 7: CI、资源断言与发布验证

**Files:**
- Modify: `.github/workflows/build-ios-ipa.yml`
- Modify: `ios-app/project.yml`
- Modify: `README.md`
- Modify: `ios-app/README.md`

- [ ] **Step 1: 在 CI 构建通用 llama.xcframework 并运行测试**

将未命中缓存时的构建改为 `MINIMAL_MODE=ios`，在 archive 前执行：

```bash
xcodebuild test \
  -project StockInventoryApp.xcodeproj \
  -scheme StockInventoryApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: 增加归档资源断言**

归档后必须找到：

```bash
test -d "$APP_PATH/mobileclip_s0_image.mlmodelc"
test -f "$APP_PATH/NextLevel-LICENSE.txt"
test -f "$APP_PATH/MobileCLIP-LICENSE.txt"
test -d "$APP_PATH/Frameworks/llama.framework"
```

- [ ] **Step 3: 生成工程并执行本地可用检查**

Run:

```bash
cd ios-app
xcodegen generate
plutil -lint StockInventoryApp/Info.plist
cd ..
git diff --check
git status --short
```

如果本机无完整 Xcode，明确记录 `xcodebuild` 无法运行，并以 GitHub Actions 的完整测试和 archive 作为最终构建证据。

- [ ] **Step 4: 完整 diff 审查与提交**

检查无临时代码、无静默 `try?` 存储失败、无逐帧 JPEG、无页面预热 VLM、无 300ms Sheet 延时。

Commit: `ci(ios): verify AI camera resources and tests`

- [ ] **Step 5: 合并并推送 main**

```bash
git switch main
git merge --ff-only feature/lumina-camera-refactor
git push origin main
```

- [ ] **Step 6: 等待 Release 并发送飞书通知**

确认 GitHub Actions 成功、`latest` Release 同时包含通用 IPA 和 Commit 后缀 IPA；再使用 `lark-im` 规范向 `oc_eb9652db889bededd01a877943c8bb26` 发送 Commit、专属直链、通用直链和 Release 页面。
