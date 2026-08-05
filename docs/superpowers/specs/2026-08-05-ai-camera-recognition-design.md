# LiveContainer AI 相机识别闭环设计

## 目标

在 iPhone 17 / iOS 26 / LiveContainer 环境中稳定走通以下闭环：拍照、图像向量生成、本地样本 Top-3 检索、低相似度时 MiniCPM-V 4.6 端侧兜底、结构化结果展示、人工确认后沉淀视觉样本。

本阶段以验证端侧可行为第一目标，同时确保形成的模块边界可直接演进为“轻量视觉向量优先、VLM 延后兜底”的正式架构。

## 已确认的问题

1. 当前 `LuminaCameraView` 并未接入 Lumina 或其他开源相机组件，而是自写 `AVCaptureVideoDataOutput` 包装。
2. 当前实现对连续视频帧逐帧执行 `CIImage -> CGImage -> UIImage -> JPEG`，在相机预览期间持续制造无意义的 CPU 与内存压力。
3. 页面出现时会预热 MiniCPM-V，相机、视觉预处理和 VLM 原生推理的内存峰值可能重叠；这与 LiveContainer 中“显示分析中数秒后退出”的现象一致。
4. `FeatureSample.visionEmbedding` 从未写入。现有本地检索只使用文本哈希，并未形成真实的图像向量闭环。
5. 相机、识别编排、持久化和 Sheet 跳转散落在 SwiftUI View 中，无法独立测试，也缺少明确的取消、失败和资源释放状态。

## 组件选型

### 相机：NextLevel 0.19.1

- 锁定 0.19.1 源码与 MIT 许可证，作为仓库内可复现依赖。
- 仅启用后置摄像头预览、静态照片捕获、自动对焦、会话启动/停止和中断恢复。
- 不启用音频、视频录制、ARKit、TrueDepth、GIF 等无关能力。
- 拍照使用 `AVCapturePhotoOutput` 的一次性照片回调，不再从视频流持续生成 JPEG。
- 相机完成 `stop` 并释放预览资源之后，才允许识别管线继续执行。

### 图像向量：MobileCLIP-S0 Core ML

- 使用 Apple 官方 MobileCLIP-S0 Core ML 模型进行端侧图像 embedding。
- 模型由 `ImageEmbeddingEngine` 延迟加载，输出统一为 L2 归一化 `[Float]`。
- 模型版本和向量维度写入样本记录，检索时拒绝比较不同版本或不同维度的向量。
- 第一阶段沿用 SwiftData `Data` 存储 Float32 向量，并使用 Accelerate/vDSP 做余弦相似度 Top-3 检索；不引入 sqlite-vec。

### VLM：OpenBMB MiniCPM-V-Apps / llama.cpp-omni

- 保留 MiniCPM-V 4.6 作为低相似度兜底，不更换底层推理框架。
- 取消业务页面出现时自动预热；只有本地向量未达到自动命中阈值时才加载。
- 同一时刻只允许一个 VLM 请求，新的识别任务必须取消旧任务或等待其结束。
- 输入图片在进入 VLM 前执行一次确定性的尺寸和方向归一化。
- 推理错误必须返回结构化失败，不允许以空结果伪装成功。

### 结果展示：原生 SwiftUI 结构化组件

- 不引入 Markdown 或聊天渲染依赖。
- 结果页展示拍摄图片、当前阶段、Top-3 候选、相似度、VLM 识别字段、最终来源和错误详情。
- 用户只能执行确认候选、选择其他候选、登记新品、手动选择、重拍或重试。
- View 不直接持有相机、Core ML 或 llama.cpp 对象。

## 模块边界

### `CameraCaptureService`

负责权限、NextLevel 配置、预览、静态拍照、会话停止与中断恢复。对外暴露状态和 `capturePhoto()` 异步接口，返回 `CapturedPhoto`。不负责压缩、推理或页面跳转。

### `CapturedImageProcessor`

负责 EXIF 方向校正、尺寸限制和 JPEG 输出。每张照片只处理一次，失败时返回明确错误。处理结束后及时释放中间图像对象。

### `ImageEmbeddingEngine`

封装 MobileCLIP Core ML 加载和图像向量生成。提供 `embed(imageData:)`，校验输出维度、有限数值和归一化结果。

### `FeatureRepository`

封装 `FeatureSample` 的保存和检索。新增视觉模型版本、向量维度字段；负责安全解码 Float32 Data、过滤损坏样本、返回按相似度排序的 Top-3。

### `VisionRecognitionPipeline`

唯一的识别编排器，状态为：

`idle -> preparingImage -> embedding -> matching -> loadingVLM -> generating -> completed/failed/cancelled`

它负责阈值决策、取消、日志和最终结果组装，不负责展示。

### `RecognitionSessionModel`

SwiftUI 可观察状态模型，将管线状态映射为进度文案、候选列表和可执行动作。相机 Sheet 关闭后由同一个页面内的状态驱动展示结果，避免连续切换两个系统 Sheet。

## 数据流与阈值

1. 用户打开相机，NextLevel 启动预览。
2. 用户拍照，静态照片回调返回原始数据。
3. 相机会话完成停止，关闭相机界面。
4. `CapturedImageProcessor` 生成方向正确、最长边受限的 JPEG。
5. MobileCLIP-S0 生成查询向量。
6. `FeatureRepository` 返回 Top-3：
   - `>= 0.85`：自动选中第一候选，仍进入结果页供确认，不调用 VLM。
   - `0.65..<0.85`：展示 Top-3 供用户选择，不调用 VLM。
   - `< 0.65` 或无样本：懒加载 MiniCPM-V 并识别名称、规格和日期。
7. 用户确认已有 SKU 时，将本次视觉向量作为新样本落库；登记新品时，在 SKU 与包装创建成功后原子保存样本。

阈值集中定义并记录到日志，便于真机验证后调整，禁止散落在 View 中。

## LiveContainer 资源策略

- 相机与 MiniCPM-V 不同时运行。
- 禁止相机预览期间逐帧 JPEG 编码。
- MobileCLIP 与 MiniCPM-V 串行执行，不并发抢占内存。
- MiniCPM-V 不在业务页面 `onAppear` 中预热。
- 进入 VLM 前记录物理内存、进程可用内存、输入图片字节数和阶段耗时。
- 临时 JPEG 使用唯一文件名，并在推理完成、失败或取消后删除。
- 收到系统内存警告时取消未开始的 VLM 任务，并向用户暴露失败原因。
- 原生 C/C++ 调用由单一串行执行器保护，禁止并发清 KV、prefill 和 generation。

## 错误处理与诊断

所有边界错误同时写入 `AppLogger` 和 `ToastManager`，至少包含：

- 相机权限、设备、会话配置、捕获与中断错误。
- 图片解码、方向、缩放与写文件错误。
- MobileCLIP 模型缺失、加载失败、输出缺失、维度错误或非有限值。
- SwiftData 查询、损坏向量、样本保存失败。
- MiniCPM-V 模型加载、图片预填、文本预填、生成、JSON 解析、超时与取消。
- 每次识别分配 `recognitionID`，所有阶段日志携带相同 ID，便于从闪退前日志还原链路。

不再使用固定 300ms 延时规避 Sheet 冲突；页面跳转由显式相机停止完成事件驱动。

## 测试与验收

### 自动测试

- 图片处理：方向、超大图、无效 Data、输出尺寸和文件体积。
- 向量编码：Float32 Data 往返、维度错误、NaN/Infinity、零向量。
- 相似度检索：精确命中、Top-3 排序、阈值边界、不同模型版本过滤、损坏样本跳过并记录。
- 管线：高分不调用 VLM、中分返回候选、低分调用一次 VLM、错误暴露、取消后不展示旧结果。
- VLM 输出解析：合法 JSON、代码围栏、缺字段、非法日期、非 JSON 原文。

### 构建验证

- 重新生成 Xcode 工程。
- 执行单元测试和 Release 配置构建。
- 检查最终 IPA 包含 NextLevel 许可证、MobileCLIP 模型及 llama.xcframework。
- 检查相机权限键和模型资源路径。

### LiveContainer 真机验收

1. 连续打开/取消相机 10 次不退出。
2. 连续拍照识别 10 次不退出，且每次只出现一个结果界面。
3. 首次无样本触发 MiniCPM-V 并展示结构化结果。
4. 确认并保存样本后，再拍同一商品能够命中 Top-3；高相似度路径不调用 MiniCPM-V。
5. 低内存、模型缺失、图片无效时显示可诊断错误，不出现假成功。
6. 运行时日志可按 `recognitionID` 查看各阶段耗时和内存信息。

## 发布

实现和本地验证通过后提交并推送当前功能分支，等待 GitHub Actions 生成 `latest` Release IPA。确认公开下载资产存在后，向项目约定的飞书会话发送 Commit、专属下载链接、通用下载链接和 Release 页面。

## 非目标

- 本阶段不引入 sqlite-vec、实时每帧识别、OCR 双通道、视频识别或云端同步。
- 不重写库存台账和单据业务。
- 不更换 MiniCPM-V 模型家族或 llama.cpp-omni 推理框架。
- 不以静默降级掩盖模型、存储或相机错误。
