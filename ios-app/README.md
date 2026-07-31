# 库存管理 · 纯离线 iOS App（不依赖后端）

基于 `docs/pure_mobile_inventory_solution.md` 落地的**零服务器、零云端 API、完全离线**餐饮原材料出入库管理系统。
所有数据存储在设备本地 SQLite（SwiftData），无任何网络请求。

## 功能
- **首页 Dashboard**：临期预警（3 天内过期）、缺货预警、快捷入库/出库/盘点入口、库存概览。
- **库存主数据**：SKU 增删改查；支持多级包装（散包/中箱/大箱/托盘），以基准单位（`base_unit`）统一记账。
- **单据流**：入库 / 出库 / 盘点。扫码（AVFoundation 条码）或手动选 SKU → 选规格 → 输入数量 → 自动换算基准数量 → 选/建批次 → 原子记账。
- **批次 FIFO**：出库自动按到期日推荐优先出库批次（先进先出）。
- **条码识别引擎**：`BarcodeEngine` 按包装条码反查 SKU；未命中进入学习模式（拍照/文本建库）。
- **离线数据备份**：一键导出/导入 JSON 数据包，通过 AirDrop / 微信 分享给其他设备恢复。
- **可插拔识别架构**：`RecognitionEngine` 协议，后续可无缝接入端侧 VLM / 向量检索（`sqlite-vec`），业务层无感知。

## 运行方式

### 方式一：XcodeGen（推荐，一条命令）
```bash
brew install xcodegen
cd ios-app
xcodegen generate        # 生成 StockInventoryApp.xcodeproj
open StockInventoryApp.xcodeproj
```
选择真机或模拟器（iOS 17+），Command + R 运行。

### 方式二：手动建工程
1. Xcode → New → iOS App，Interface: SwiftUI，Storage: None（本工程自带 SwiftData 容器），Product Name: `StockInventoryApp`。
2. 删除自动生成的 `ContentView.swift` / `Assets` 中无用项（保留 App 入口文件）。
3. 将本目录 `StockInventoryApp/` 下所有 `.swift` 拖入工程（勾选 target 成员）。
4. 在 Target → Info → Custom iOS Target Properties 添加 `NSCameraUsageDescription`（扫码需要）。
5. 运行（iOS 17+）。

## 代码结构
```
StockInventoryApp/
├── StockInventoryAppApp.swift     # @main 入口 + ModelContainer
├── Models/                        # SwiftData 模型（映射方案 DDL）
│   ├── RawMaterialSKU / PackagingUnit / FeatureSample
│   ├── StockBatch / StockInventory / StockOrderHeader / StockOrderItem
│   └── StockModelContainer.swift
├── Engine/                        # 可插拔识别引擎
│   ├── RecognitionEngine.swift    # 协议 + 结果类型
│   ├── BarcodeEngine.swift        # 条码识别（首版）
│   └── ManualEngine.swift         # 手动识别
├── Store/
│   ├── InventoryStore.swift       # 换算 / FIFO / 原子记账 / 预警
│   └── ExportImport.swift         # JSON 离线数据包
├── Views/                         # SwiftUI 界面
│   ├── MainTabView / DashboardView / SKUListView / SKUDetailView
│   ├── SKUFormView / OrderCreateView / OrderHistoryView / SettingsView
│   └── BarcodeScannerView.swift   # AVFoundation 扫码浮层
└── Theme.swift / Extensions/Formatters.swift
```

## 与方案文档的对应关系
| 方案 DDL | 本工程模型 |
|---|---|
| raw_material_sku | RawMaterialSKU |
| sku_packaging_unit | PackagingUnit |
| material_feature_sample | FeatureSample（学习模式存本地样本图，向量字段预留） |
| stock_batch | StockBatch |
| stock_inventory | StockInventory |
| stock_order_header / item | StockOrderHeader / StockOrderItem |

## 已知边界（v1）
- **端侧 ML 推理**：首版未集成 PP-OCR / MobileNetV4 / MiniCPM-V；识别引擎接口已预留，后续按 `IRecognitionEngine` 接入。
- **Excel 导出**：首版导出为 JSON（无后端依赖更通用）；Excel 可作为后续扩展。
- **P2P WiFi 同步**：方案中的局域网同步为选配，本版未实现，JSON 数据包已覆盖多设备迁移需求。
- **向量检索（sqlite-vec）**：`FeatureSample.visionEmbedding/textEmbedding` 以 `Data` 预留，后续接入本地向量索引。
- 编译验证需在 Xcode 中执行（本仓库未包含 macOS 构建环境）。
