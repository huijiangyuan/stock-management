# Stock Management · 餐饮原材料智能出入库（纯离线 iOS）

一款**完全不依赖后端服务器**的餐饮原材料出入库管理 App：SwiftUI + SwiftData（本地 SQLite），条码/手动识别、多级包装换算、批次 FIFO、临期/缺货预警、JSON 离线导入导出。

## 目录结构
- `docs/`：方案文档（含纯移动端离线方案 `pure_mobile_inventory_solution.md`）
- `ios-app/`：iOS 工程（XcodeGen `project.yml` 生成 `.xcodeproj`）
- `.github/workflows/build-ios-ipa.yml`：GitHub Actions 构建未签名 IPA

## 构建与安装
本仓库通过 GitHub Actions 生成**未签名 IPA**，配合 **SideStore + LiveContainer** 免费侧载到真机（无需 Apple 开发者年费）。详见 `ios-app/README.md`。

```bash
# 本地生成 Xcode 工程（需本机装 xcodegen）
brew install xcodegen && cd ios-app && xcodegen generate
```

## 技术要点
- 数据模型 1:1 映射方案 DDL 的 7 张本地表
- 可插拔识别引擎（条码 / 手动；端侧 VLM、向量检索为预留扩展点）
- 5 条硬约束：base_unit 唯一基准 / 批次 FIFO / 单据原子性 / 完全离线 / 引擎可插拔
