# StockManager 项目 Agent 工程指南

> Scope: 适用于本仓库及其子目录（上游子模块自带的 `AGENTS.md` 另行生效）。本文档是 StockManager 的项目级工程约束、技术架构索引和构建发布手册。

## 0. 执行原则

- 默认使用简体中文，结论先行，只保留可复核的修改、验证和风险。
- 以当前代码、`ios-app/project.yml` 和 `.github/workflows/build-ios-ipa.yml` 为事实源；`README.md` 和 `docs/` 可能保留早期“预留接口”描述，不得用旧文档覆盖当前实现。
- 先追踪端到端链路，再做最小修复。相机闪退、识别卡住等问题必须按“取流 → 拍照事务 → 图片预处理 → embedding → 本地检索 → VLM 兜底 → 结果页”排查，不做单点猜修。
- 禁止静默回退和虚假成功。所有相机、AI、模型、SwiftData 与网络错误必须进入 `AppLogger`；`.error` / `.warning` 会通过 `ToastManager` 向用户暴露。
- 未经用户明确授权，不自动合并到 `main`、不推送共享分支、不创建 PR、不覆盖 GitHub Release。分支构建与公开发布必须明确区分。

## 1. 产品定位与运行边界

- 产品：纯移动端智能出入库与通用商品/物料管理应用。
- 平台：iOS 17+，SwiftUI + SwiftData，目标真机包括 iPhone 17 / iOS 26。
- 侧载：主要交付未签名 IPA，供 LiveContainer / SideStore / TrollStore 安装。
- 数据：库存、SKU、批次、单据、特征向量默认只存本地；模型下载和可选云端 VLM 是显式网络能力，不得将“本地优先”误写为“运行期绝无网络”。
- 当前技术路线：轻量视觉向量优先，MiniCPM-V 4.6 延后兜底；不要把重型 VLM 放回每次拍照的首选路径。

## 2. 技术架构

### 2.1 端到端识别链路

```text
CameraCaptureView / vendored NextLevel
  → AVCapturePhotoCaptureDelegate 完整拍照事务
  → CapturedImageProcessor（EXIF 旋转、最长边 1024、JPEG 0.82）
  → MobileCLIPEmbeddingEngine（Core ML / CPU + Neural Engine）
  → FeatureRepository + LocalFeatureEngine（SwiftData + vDSP 余弦相似度）
  → Top-12 候选去重为 Top-3 SKU
  → 相似度 >= 0.65：返回本地候选；>= 0.85：可高置信度选中
  → 未命中：按 VisionSettings 选择 MiniCPM-V 4.6 / 云端 VLM
  → AIRecognitionResultView（来源、置信度、Top-3、确认/建库/手选/重拍）
```

关键入口：

| 职责 | 事实源 |
|---|---|
| 静态拍照和会话生命周期 | `ios-app/StockInventoryApp/Views/CameraCaptureView.swift` |
| 图片预处理 | `Engine/CapturedImageProcessor.swift` |
| MobileCLIP 推理 | `Engine/ImageEmbeddingEngine.swift` |
| 本地特征存储与 Top-K | `Engine/FeatureRepository.swift` |
| Float32 编解码与 vDSP 余弦相似度 | `Engine/LocalFeatureEngine.swift` |
| 识别编排和阈值 | `Engine/VisionRecognitionPipeline.swift` |
| MiniCPM-V 业务封装 | `OnDevice/OnDeviceVisionEngine.swift` |
| GGUF 下载、SHA-256 校验与加载 | `OnDevice/ModelManager.swift` |
| Swift ↔ llama 边界 | `OnDevice/MBMtmd.h` + `MBMtmd.mm` |
| 识别结果展示 | `Views/AIRecognitionResultView.swift` |

### 2.2 本地数据与库存领域

- SwiftData schema 由 `StockModelContainer.swift` 统一声明，共 7 个模型：`RawMaterialSKU`、`PackagingUnit`、`FeatureSample`、`StockBatch`、`StockInventory`、`StockOrderHeader`、`StockOrderItem`。
- 数量统一以 SKU `baseUnit` 记账；规格数量通过 `conversionRatio` 换算，不得绕过该换算直接修改库存。
- `InventoryStore.processOrder` 在同一 `ModelContext` 中创建单头、明细和库存变更，最后只调用一次 `context.save()`。修改时必须保持这一保存边界，不要在循环内提前 save。
- 出库批次按到期日升序推荐 FIFO；盘点 `CHECK` 是覆盖基准数量，入库/出库是增减。
- `FeatureSample.visionEmbedding` 是 Float32 原始字节，必须同时比对 `visionModelVersion` 和 `visionVectorDimension`。不允许把不同模型或不同维度的向量混在一次检索中。
- 样本图存在 Application Support/`FeatureSamples`，向量和关系存 SwiftData。数据库保存失败时必须回滚当次样本对象并清理图片文件。

### 2.3 MiniCPM-V / llama.cpp-omni

- MiniCPM-V 4.6 模型不随 IPA 打包。`ModelManager` 从 ModelScope / HuggingFace / 自定义 HTTPS 地址下载约 1.6 GB 的 GGUF + mmproj，也可从 App Documents 扫描用户手动放入的文件。
- 官方源使用内置 SHA-256 做 fail-closed 校验；不匹配必须删除并拒绝加载，不得添加“继续使用”绕过。
- 侧载环境当前强制 `useGPU=false` / `mmprojUseGPU=false`，并由 `OnDeviceSafeEnvironment` 做内存和运行环境准入。不得为追求速度直接恢复 Metal，除非已有 iPhone 17 / iOS 26 / LiveContainer 真机压测证据。
- MiniCPM-V 4.6 GGUF 官方 CPU 运行口径约 2 GB、推荐设备 RAM 至少 6 GB。本项目加载前要求进程可用内存至少 2.7 GB，加载后每次图片推理前至少保留 1.5 GB；阈值变化必须有真机峰值内存证据。
- MobileCLIP 未命中后必须先尝试 MiniCPM-V。不得增加绕过端侧 VLM 的偏好开关；模型缺失或内存准入失败时必须明确提示，之后才允许按配置进入云端兜底。
- 原生 llama 上下文不可并发进入。`OnDeviceVisionEngine` 必须保持单任务门禁，新识别前清理 KV cache，取消要经由 wrapper 停止生成。
- `llama.xcframework` 由 `ios-app/scripts/build_xcframework.sh` 从 `ios-app/llama.cpp-omni` 子模块生成，不入 Git。更新子模块 commit、构建脚本或 Xcode 版本后必须重建，CI 会以这三者组合生成缓存 key。

### 2.4 Swift / Objective-C++ 隔离红线

- Swift 只能通过 `MBMtmd.h` 暴露的纯 C API 访问 llama/mtmd；C++ 头文件和实现必须收敛在 `MBMtmd.mm`。
- 禁止在 Swift 文件中 `import llama`。
- 禁止全局开启 `SWIFT_OBJC_INTEROP_MODE: objcxx`。这会让所有 Swift 编译单元导入 llama C++ 类型，重现 `mtmd::bitmap` 不可拷贝、`string file not found` 或 Objective-C module 构建失败。
- `SWIFT_OBJC_BRIDGING_HEADER`、C++20、framework link/embed 配置只在 `ios-app/project.yml` 维护，不直接修改生成的 `.xcodeproj`。

## 3. 相机生命周期约束

- 相机组件使用仓库内 vendored NextLevel `0.19.1`，兼容性修补记录在 `ios-app/Vendor/NextLevel/PATCHES.md`。不得用系统 `UIImagePickerController` 或另一套自建取流器和 NextLevel 并行竞争相机。
- 正确拍照顺序：
  1. `state == .running` 且 `canCapturePhoto` 时发起拍照；
  2. `capturePhoto()` 必须显式返回是否真正提交给 `AVCapturePhotoOutput`；
  3. `didFinishProcessingPhoto` 只接收和保存数据，不得在此停止 session；
  4. 必须等 `didFinishCaptureFor` / `nextLevelDidCompletePhotoCapture` 表明完整拍照事务结束；
  5. 然后在 NextLevel session queue 上停止会话、移除 input/output，主线程完成回调；
  6. 释放 delegate 后再 dismiss 相机 sheet 并把图片交给 AI 流水线。
- 拍照和停止会话必须有超时保护，但超时是显式错误恢复，不是“成功回调”。
- SwiftUI sheet 切换必须先完成相机 dismiss，再启动识别和展示结果 sheet；禁止同时修改两个 modal 状态。
- 模拟器没有真实相机事务，GitHub CI 能验证编译和单测，不能证明“真机拍照已修复”。最终验收必须使用 iPhone 17 / iOS 26 / LiveContainer 连续拍照、重拍、取消和中断恢复。

## 4. 模型、资源与安全

- MobileCLIP Core ML 资源位于 `StockInventoryApp/Resources/mobileclip_s0_image.mlpackage`，CI 会断言编译后的 `mobileclip_s0_image.mlmodelc` 存在且大于 10 MB。
- MobileCLIP 权重当前用于 POC/可行性验证；商业发布前必须重新审核模型权重许可。`MobileCLIP-LICENSE_MODELS.txt` 和 `NextLevel-LICENSE.txt` 必须随 App 入包。
- API Key 只存 Keychain，不进 `UserDefaults`、源码、日志或 CI artifact。
- 自定义模型地址必须是 HTTPS 且不能指向本机/内网。
- 任何降低图片尺寸、上下文、`n_ubatch`、图片 token 或量化精度的修改，都必须同时评估峰值内存、识别质量和 LiveContainer 稳定性。

## 5. 项目与依赖管理

- `ios-app/project.yml` 是 Xcode 工程单一事实源；`ios-app/StockInventoryApp.xcodeproj` 是忽略的生成物。
- 新增/删除/移动 Swift、资源或 target 文件后，必须在 `ios-app/` 运行 `xcodegen generate`。不提交 `.xcodeproj`、`DerivedData`、`Frameworks/llama.xcframework`、`build/` 或 IPA。
- `Info.plist` 由 `INFOPLIST_FILE: StockInventoryApp/Info.plist` 手写管理。不得改回 XcodeGen 自动生成，否则可能抹掉相机/相册权限键并在真机触发 TCC `SIGABRT`。
- `ios-app/llama.cpp-omni` 是 Git submodule。克隆、CI 和本地原生构建必须使用 recursive submodule；不在主项目任务中顺手修改子模块内容。
- vendored NextLevel 已有 Swift 6/iOS SDK 兼容补丁。升级上游版本时先对照 `PATCHES.md`，逐条证明补丁已上游化或重新移植。

## 6. 本地开发与验证

### 6.1 环境

- 完整构建需要 Xcode，只有 `/Library/Developer/CommandLineTools` 时不能运行 iOS `xcodebuild`，必须明确降级为静态检查并使用 GitHub Actions 构建。
- 初始化：

```bash
git submodule update --init --recursive
brew install xcodegen cmake
cd ios-app
xcodegen generate
```

- 需要本地构建 llama framework 时：

```bash
cd ios-app
MINIMAL_MODE=ios ./scripts/build_xcframework.sh
```

### 6.2 修改后最小自检

```bash
git status --short --branch
git diff --check
cd ios-app
xcodegen generate
plutil -lint StockInventoryApp/Info.plist
rg --files StockInventoryApp StockInventoryAppTests Vendor/NextLevel/Sources -g '*.swift' -0 \
  | xargs -0 xcrun swiftc -frontend -parse -parse-stdlib
```

有完整 Xcode 和 simulator framework 时，再运行：

```bash
cd ios-app
xcodebuild test \
  -project StockInventoryApp.xcodeproj \
  -scheme StockInventoryApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

### 6.3 测试边界

- 向量层：覆盖字节数不对齐、NaN/Inf、零范数、维度不一致、模型版本不一致、Top-K 排序和 SKU 去重。
- 识别管道：覆盖高置信向量直返、低置信候选、无样本、embedding 失败转 VLM、取消。
- 库存：覆盖包装换算、入/出/盘、FIFO、批次、预警和导入导出。
- 相机：至少真机验证首次拍照、连续 10 次、拍照后立即重拍、取消、App 切后台/回前台、权限拒绝、低内存。CI 通过不能替代这些项目。

## 7. GitHub Actions / IPA 构建

工作流：`.github/workflows/build-ios-ipa.yml`，主 job 使用 `macos-15`。

### 7.0 可见构建身份（强制）

- 每次修改都必须保证首页和设置页可见显示：应用版本、构建号、构建日期和 Git Commit 短码。
- 版本信息只能从 App Bundle 的 `Info.plist` 读取，禁止在 Swift 源码中写死展示值。
- GitHub Actions 构建必须用实际 checkout commit、北京时间构建日期和 Actions run number 注入 Bundle；不得使用工作流触发事件中可能偏离 checkout 的旧 SHA。
- CI 必须校验归档 App 的 `CFBundleShortVersionString`、`CFBundleVersion`、`StockBuildDate`、`StockGitCommit` 与本次构建一致。缺任一项应直接失败，禁止产出无法辨认版本的 IPA。

### 7.1 触发语义

- `push main`：自动构建，成功后同时更新公开 `latest` Release。
- `workflow_dispatch`：可构建分支/tag/SHA。非 `main` 运行只上传保留 30 天的 Actions artifact，不覆盖公开 Release。
- `SIGNED_BUILD=true` 时会额外运行付费开发者证书签名 job；缺失证书/Provisioning Profile Secrets 时不得尝试伪造签名产物。
- 禁止把“分支 artifact 已上传”表述为“`latest` 公开包已发布”。

手动触发示例：

```bash
gh workflow run build-ios-ipa.yml \
  --ref <branch> \
  -f ref=<branch>
```

### 7.2 CI 验证链

1. recursive checkout 子模块；
2. 选择 Xcode，安装 XcodeGen / CMake；
3. 命中或构建 device + simulator `llama.xcframework`；
4. `xcodegen generate`；
5. iOS Simulator 单元测试；
6. 无签名 Release Archive；
7. 断言 `NSCameraUsageDescription`、`NSPhotoLibraryUsageDescription`、`NSPhotoLibraryAddUsageDescription`；
8. 断言 MobileCLIP 编译资源和许可文件入包；
9. 打包 `StockInventoryApp-unsigned.ipa` 和 `StockManager-<short_sha>.ipa`；
10. 上传 `StockInventoryApp-unsigned-ipa` artifact；
11. 仅 `refs/heads/main` 更新 `latest` Release。

### 7.3 构建完成标准

- Actions job 结论为 `success`，且上述步骤不得有被跳过的必需项。
- 必须查到 artifact / Release 资产名、大小、ID/URL。
- 可下载时应实际下载 IPA，执行 `unzip -tq` 并记录 SHA-256。仅 Release API 显示 `uploaded` 不等于本机下载验证通过。
- 报告时必须写明：构建 commit、分支、run ID、结论、下载方式、SHA-256 和真机未覆盖项。

### 7.4 公开 Release 链接

- 通用 IPA：`https://github.com/huijiangyuan/stock-management/releases/download/latest/StockInventoryApp-unsigned.ipa`
- 本次 commit IPA：`https://github.com/huijiangyuan/stock-management/releases/download/latest/StockManager-<short_sha>.ipa`
- Release 页：`https://github.com/huijiangyuan/stock-management/releases/tag/latest`

只有 `main` 的发布 job 成功后才能发送上述公开直链。分支构建应发送对应 run 的 artifact 链接，并注明下载需要 GitHub 登录。

## 8. 提交、推送、发布与飞书通知

### 8.1 Git 操作边界

- 开发前报告当前分支、上游和 dirty 状态；用户已有修改不得被暂存、覆盖、丢弃或顺带提交。
- 本地验证完成后展示变更范围和建议 commit message。提交、合并、推送、PR 是独立动作，按用户授权执行。
- 需要验证修复分支时，推送该分支并使用 `workflow_dispatch`；不为了获得公开链接擅自合并 `main`。

### 8.2 飞书通知

- 发送前确认收件人/群、消息内容和发送身份。既定发布会话为「汇匠源」群 `oc_eb9652db889bededd01a877943c8bb26`，默认使用已授权的 `--as user`；改用 bot 需单独确认。
- 只有在 CI 成功且下载资产存在后才发送“构建成功”通知。失败时发 run 链接、失败步骤和下一步，不发虚假下载链接。
- 成功通知至少包含：commit、分支、Actions run、验证结果、SHA-256、IPA 下载链接、LiveContainer 适用性和是否需要 GitHub 登录。
- 未经明确授权，只发送消息和下载链接，不直接向群上传 IPA 二进制文件。

示例：

```bash
lark-cli im +messages-send \
  --as user \
  --chat-id oc_eb9652db889bededd01a877943c8bb26 \
  --markdown $'🚀 **StockManager iOS 构建成功**\n\n- Commit: `<sha>`\n- CI: <run-url>\n- SHA-256: `<digest>`\n\n📥 [下载 IPA](<artifact-or-release-url>)'
```

## 9. 完成定义

一个相机/AI/库存任务只有同时满足以下条件才可以声称“完成”：

1. 修改与用户确认的范围一致，无无关 Diff；
2. `git diff --check`、XcodeGen、Info.plist 校验和对应测试通过；
3. 需要 IPA 时，GitHub Actions 和资产校验通过；
4. 依赖相机/原生模型的功能完成真机验收，或明确写出尚未覆盖；
5. 错误可在 App 诊断日志和 UI Toast 中观测；
6. 交付信息包含分支、commit、验证命令/结果、风险与下载方式。
