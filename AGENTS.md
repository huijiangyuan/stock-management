# StockManager 项目 Agent 行为与工作流指南

> Scope: 本文件定义 StockManager (纯端侧 AI 智能出入库与商品物料管理系统) 项目专属的指令规范、协作规则与自动化构建发布工作流。

---

## 0. 项目核心架构与定位

- **产品定位**：纯端侧 AI 智能出入库与通用商品物料管理系统。适用于餐饮食材、零售商品、数码零配件、服装鞋帽等任意物料。
- **技术选型**：iOS 17+ / SwiftData (SQLite) 纯离线持久化 + Apple Accelerate (vDSP) 512 维 Float32 向量余弦相似度计算 + 嵌入式 MiniCPM-V 4.6 端侧推理（云端 VLM 兜底）。
- **运行环境**：支持 SideStore / TrollStore / LiveContainer 侧载免证书安装。

---

## 1. 打包发布与飞书自动推送标准化工作流 (Release Workflow)

当用户发出“提交构建”、“打包推送”或相关发布下令时，必须严格执行以下标准工作流：

### Step 1: 代码变更与本地自检
- 修改视图或逻辑后，执行 `git status -s` 检查文件变动，确保无赘余临时代码。
- 若新增 `.swift` 源代码文件，**必须**在 `ios-app/` 目录下执行 `xcodegen generate` 重新合成 `.xcodeproj` 工程文件，避免源文件丢包。
- **安全防线**：代码修改完成展示 diff 与自检结果，停留在本地工作区，**绝不主动** `git push` 到任何远端，必须等待用户明确下令才执行远端操作。

### Step 2: Git 提交与远程推送
当收到用户明确的远端下令后，执行：
```bash
git add .
git commit -m "<type>(<scope>): <description>"
git push origin main
```

### Step 3: CI 流水线与 GitHub Release 自动发布
- 仓库 Actions 触发 `.github/workflows/build-ios-ipa.yml` 流水线。
- 构建步骤自动完成 Xcode 编译、Info.plist 权限断言、Package 生成未签名 IPA 附件。
- 工作流内置 `permissions: contents: write` 与 `softprops/action-gh-release@v2`，自动将打好的 IPA 文件上传发布至公开 Release (`latest` tag)。
- **公开免登录直链规范**：
  - 附件公开直链：`https://github.com/huijiangyuan/stock-management/releases/download/latest/StockInventoryApp-unsigned.ipa`
  - Release 页面：`https://github.com/huijiangyuan/stock-management/releases/tag/latest`

### Step 4: 飞书 (Lark) 消息自动推送
- 待 GitHub Actions 构建完成且 Release 资产生成后，自动调用飞书消息工具向指定会话（如「汇匠源」群 `oc_eb9652db889bededd01a877943c8bb26`）发送 Markdown 格式通知：
```bash
lark-cli im +messages-send --as user --chat-id <chat_id> --markdown $'🚀 **StockManager 最新 iOS 侧载安装包 (.ipa) 构建成功！**\n\n- **版本/Commit**: `<commit_hash>`\n- **说明**: 附件已公开发布，点击以下链接免登录直接下载 `.ipa` 安装包。\n\n📥 **IPA 文件直接下载链接**:\n[https://github.com/huijiangyuan/stock-management/releases/download/latest/StockInventoryApp-unsigned.ipa](https://github.com/huijiangyuan/stock-management/releases/download/latest/StockInventoryApp-unsigned.ipa)\n\n📌 **Release 公开页面**:\n[https://github.com/huijiangyuan/stock-management/releases/tag/latest](https://github.com/huijiangyuan/stock-management/releases/tag/latest)'
```

---

## 2. 运行时诊断与异常暴露防线

- **禁止静默回退**：暴露出所有的显式错误与异常，严禁编写静默回退、虚假成功路径以掩盖问题。
- **AppLogger & ToastManager**：所有相机会话、AI 识别、数据库 Save 及网络 API 错误，必须通过 `AppLogger.shared.log()` 记录，并通过 `ToastManager` 在 UI 顶端弹框暴回给用户。
- **端侧日志查阅**：用户或测试人员可在 App「设置 → 运行时诊断日志」实时查阅、展开堆栈及一键复制日志排障。
