# 纯移动端餐饮原材料智能出入库管理系统设计方案 (Standalone Edge-Only Architecture)

## 一、 方案定位与设计思想

本方案专为**零服务器依赖、零云端 API 成本、完全离线独立运行**的移动端应用（Android 智能手机 / PDA 手持终端 / iOS）设计。

系统将 **端侧视觉识别 + 端侧轻量 OCR + 端侧向量检索 + 端侧量化 VLM + 端侧 SQLite 数据库** 深度集成在单台移动设备上。即使在无网冷库、地下室或无服务器部署预算的独立门店中，也能实现毫秒级商品识别、多级包装换算与库存记账。

---

## 二、 纯移动端整体架构设计

全局业务逻辑与 AI 引擎全部运行在手机本地（CPU / GPU / NPU）：

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               移动端 App (Standalone Mobile App)                        │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              UI 交互与业务控制层                                  │  │
│  │ - 实时摄像头扫描/识别界面  - 学习模式(新品/新包装拍照注册)  - 出入库/盘点单据管理  │  │
│  └───────────────────────────────────────┬──────────────────────────────────────────┘  │
│                                          │                                             │
│  ┌───────────────────────────────────────▼──────────────────────────────────────────┐  │
│  │                              端侧智能识别引擎 (Edge AI)                          │  │
│  │                                                                                  │  │
│  │ ┌────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────┐ │  │
│  │ │ 实时帧处理(CameraX)    │  │ 双通道特征提取          │  │ 端侧向量检索        │ │  │
│  │ │ - 帧率控制 (15-30fps)  │  │ - PP-OCRv4-tiny (MNN)   │  │ - SQLite-vec        │ │  │
│  │ │ - ROI 区域自动裁剪     │  │ - MobileNetV4 (Embedding)│ │ - 余弦相似度耗时<5ms│ │  │
│  │ └────────────────────────┘  └─────────────────────────┘  └─────────────────────┘ │  │
│  │                                          │ (相似度 < 0.65 时离线激活)            │  │
│  │                             ┌────────────▼─────────────┐                         │  │
│  │                             │ 端侧量化 VLM (MiniCPM-V) │                         │  │
│  │                             │ - 本地 NPU/GPU 离线推理  │                         │  │
│  │                             │ - 自动提取商品名与规格   │                         │  │
│  │                             └──────────────────────────┘                         │  │
│  └───────────────────────────────────────┬──────────────────────────────────────────┘  │
│                                          │                                             │
│  ┌───────────────────────────────────────▼──────────────────────────────────────────┐  │
│  │                              端侧数据库与本地存储 (SQLite Engine)                 │  │
│  │ - SKU主表 (raw_material_sku)     - 多级包装表 (sku_packaging_unit)               │  │
│  │ - 特征向量表 (material_feature)  - 批次与台账 (stock_batch, stock_inventory)     │  │
│  │ - 业务单据 (stock_order_header)  - 离线数据导入/导出 (Excel / CSV / JSON)        │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 三、 端侧核心技术栈选型

| 模块 | 推荐选型 | 选用理由 / 性能表现 |
| :--- | :--- | :--- |
| **应用开发框架** | **Flutter / Android Native (Kotlin)** | 高性能渲染与实时 Camera 图像流处理支持；Flutter 可一套代码同时跑 Android 与 iOS |
| **实时摄像头采集** | **CameraX (Android) / AVFoundation (iOS)** | 原生硬件加速，支持设置 ROI 识别框，降低每帧处理尺寸（降采样至 $640 \times 640$ 提升速度） |
| **AI 推理引擎** | **Alibaba MNN / ExecuTorch** | 移动端性能最强轻量推理引擎，完整支持 CPU/NPU/GPU 加速，内存占用极小 |
| **端侧轻量 OCR** | **PP-OCRv4-tiny (MNN 格式)** | 内存占用仅 10MB，单帧文本提取耗时 $15\text{ms} \sim 30\text{ms}$ |
| **端侧视觉 Embedding** | **MobileNetV4 / EfficientNet-Lite** | 模型体积 $< 15\text{MB}$，将图像压缩导出为 512 维 Float32 特征向量，耗时 $< 20\text{ms}$ |
| **端侧向量数据库** | **`SQLite` + `sqlite-vec`** | 纯 C 编写，无网络开销，在手机端检索 5 万条向量仅需 $3\text{ms} \sim 5\text{ms}$ |
| **端侧离线 VLM (兜底)** | **MiniCPM-V 2.6 (1.5B / 2.6B int4 量化)** | 借由 MNN-LLM 运行，在主流手机（如骁龙 8 Gen2/3）上实现纯离线看图识别，耗时 $\sim 1\text{s}$ |

---

## 四、 纯移动端业务流程与自学习闭环

在完全没有服务器的前提下，应用通过“**端侧闭环人机协同**”解决新品类与新包装的识别问题。

```
                       ┌─── [相似度 S ≥ 0.85] ───> 【识别成功】 ──> 自动锁定 SKU 与包装规格 (如 大箱)
                       │
[手机扫描图像帧] ──> 【端侧双通道检索】
                       │
                       ├─── [0.65 ≤ S < 0.85] ───> 【弹窗推荐】 ──> 展示 Top-3 候选品类供员工一键确认
                       │
                       └─── [相似度 S < 0.65] ───> 【激活端侧 VLM 或 学习模式】 ──┐
                                                                                   │
                                                                                   ▼
                                                                        [端侧 VLM 自动提取文本/规格]
                                                                                   │
                                                                                   ▼
                                                                        [员工确认/手动修正输入]
                                                                                   │
                                                                                   ▼
                                                                        [本地立刻生成特征向量落库]
                                                                                   │
                                                                                   ▼
                                                                        【以后扫描该包装实现毫秒级秒刷】
```

---

## 五、 纯移动端本地数据库 DDL 设计 (SQLite)

所有数据完全保存在手机本地 `app_database.db` 文件中。

```sql
-- 1. 原材料 SKU 主表
CREATE TABLE IF NOT EXISTS raw_material_sku (
    sku_id VARCHAR(64) PRIMARY KEY,
    sku_code VARCHAR(64) UNIQUE NOT NULL,       -- 商品编码 (如: SKU-1001)
    sku_name VARCHAR(128) NOT NULL,              -- 商品名称 (如: 精品肥牛卷)
    category_name VARCHAR(64) NOT NULL,          -- 品类 (如: 肉类/冻品)
    base_unit VARCHAR(32) NOT NULL DEFAULT '包', -- 最小基础计数单位
    shelf_life_days INT DEFAULT 0,               -- 保质期天数 (用于离线 FIFO 预警)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. 多级包装规格表 (散包/中箱/大箱)
CREATE TABLE IF NOT EXISTS sku_packaging_unit (
    unit_id VARCHAR(64) PRIMARY KEY,
    sku_id VARCHAR(64) NOT NULL,
    unit_name VARCHAR(32) NOT NULL,              -- 规格名称 (散包 / 中箱 / 大箱)
    unit_type VARCHAR(20) NOT NULL,              -- BASE (1包), MID (10包), LARGE (50包)
    conversion_ratio DECIMAL(10, 2) NOT NULL,    -- 换算成 base_unit 的系数
    barcode VARCHAR(64),                         -- 包装上的条码 (如有)
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id) ON DELETE CASCADE
);

-- 3. 端侧特征向量与包装多角度参考图表
CREATE TABLE IF NOT EXISTS material_feature_sample (
    sample_id VARCHAR(64) PRIMARY KEY,
    unit_id VARCHAR(64) NOT NULL,                -- 绑定具体包装规格
    sku_id VARCHAR(64) NOT NULL,
    angle_tag VARCHAR(32) DEFAULT 'FRONT',       -- 角度标记: FRONT, SIDE, MARK
    ocr_text_content TEXT,                       -- 该角度提取的核心文本
    vision_embedding_blob BLOB NOT NULL,       -- 512 维 Float32 视觉特征向量
    text_embedding_blob BLOB NOT NULL,         -- 384 维 Float32 文本特征向量
    sample_image_path TEXT,                    -- 本地图片存储路径
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (unit_id) REFERENCES sku_packaging_unit(unit_id) ON DELETE CASCADE
);

-- 4. sqlite-vec 本地向量检索虚表
CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING vec0(
    sample_id TEXT PRIMARY KEY,
    fusion_embedding float[512] distance_metric=cosine
);

-- 5. 本地库存批次表 (FIFO 管理)
CREATE TABLE IF NOT EXISTS stock_batch (
    batch_id VARCHAR(64) PRIMARY KEY,
    batch_no VARCHAR(64) UNIQUE NOT NULL,       -- 批次号 (如: SKU1001-20260731-01)
    sku_id VARCHAR(64) NOT NULL,
    production_date DATE,                        -- 生产日期 (识别或手动输入)
    expiration_date DATE,                        -- 到期日期
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id)
);

-- 6. 本地实时库存台账表
CREATE TABLE IF NOT EXISTS stock_inventory (
    inventory_id VARCHAR(64) PRIMARY KEY,
    location_name VARCHAR(64) DEFAULT '默认货位',-- 本地简易货位 (如: A1冷库)
    sku_id VARCHAR(64) NOT NULL,
    batch_id VARCHAR(64) NOT NULL,
    qty_base_unit DECIMAL(12, 2) NOT NULL DEFAULT 0, -- 换算后的基础单位剩余总数
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(location_name, sku_id, batch_id),
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id),
    FOREIGN KEY (batch_id) REFERENCES stock_batch(batch_id)
);

-- 7. 移动端出入库/盘点单据头表
CREATE TABLE IF NOT EXISTS stock_order_header (
    order_id VARCHAR(64) PRIMARY KEY,
    order_no VARCHAR(64) UNIQUE NOT NULL,       -- 单据号 (如: IN-20260731-001)
    order_type VARCHAR(20) NOT NULL,             -- INBOUND, OUTBOUND, CHECK
    remark TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 8. 移动端单据明细表
CREATE TABLE IF NOT EXISTS stock_order_item (
    item_id VARCHAR(64) PRIMARY KEY,
    order_id VARCHAR(64) NOT NULL,
    sku_id VARCHAR(64) NOT NULL,
    unit_id VARCHAR(64) NOT NULL,                -- 识别出的规格
    batch_id VARCHAR(64),
    operating_qty DECIMAL(10, 2) NOT NULL,       -- 操作数量 (例如 2)
    conversion_ratio DECIMAL(10, 2) NOT NULL,    -- 换算系数 (50)
    total_base_qty DECIMAL(12, 2) NOT NULL,      -- 换算后总包数 (100)
    FOREIGN KEY (order_id) REFERENCES stock_order_header(order_id) ON DELETE CASCADE
);
```

---

## 六、 纯移动端备份、恢复与多设备交互方案

由于系统完全运行在移动端，数据的备份与多手机间共享采用以下**去中心化/轻量化**机制：

1. **一键导出 / 导入 (Excel & JSON 数据包)**：
   - 支持将商品主数据、SKU 特征包、库存台账一键导出为标准的 `.xlsx` 或加密 `.json` 数据包。
   - 库管员可以通过微信、邮件或 AirDrop 共享给其他手机，直接一键恢复/导入。
2. **局域网点对点同步 (P2P WiFi Sync - 选配)**：
   - 同一门店多台 PDA / 手机在同一个局域网（WiFi）下，基于 WebSocket / mDNS 自动发现设备。
   - 主设备（Leader Phone）作为临时微型 Server，其他子设备扫码提交的单据自动合并至主设备。
3. **离线 FIFO 临期预警**：
   - 每天打开 App 时，端侧自动扫描 `stock_inventory` 与 `stock_batch`。
   - 根据本地时间计算保质期剩余天数，在 App 首页弹窗提示：“包含 3 种即将在 3 天内过期的原材料，请优先出库”。
