# 餐饮原材料智能库存管理系统（WMS/ERP）整体工程落地与架构设计文档

## 一、 系统定位与整体架构设计

本方案以**实际工程落地**和**高扩展性**为前提，将 AI 智能视觉识别（双通道特征比对 + VLM 兜底）作为智能数据采集终端，无缝集成至完整的餐饮库存管理系统（WMS / Inventory ERP）中。

系统采用 **“端侧离线优先（Offline-First） + 云端分布式协同”** 架构，确保在冷库、地下室等弱网/无网环境下依然能够完成毫秒级智能识别与出入库记账。

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                移动端 App / PDA 手持终端                                   │
│  ┌──────────────────────┐   ┌──────────────────────────┐   ┌───────────────────────────┐  │
│  │ 智能感知与识别引擎   │   │  端侧离线单据与事务引擎  │   │  端侧 SQLite 数据库       │  │
│  │ - 文本/视觉双通道    │   │ - 入库/出库/盘点/调拨单   │   │ - SKU/规格/批次表         │  │
│  │ - 向量比对 (SQLite-vec)│  │ - 幂等离线队列 (Offline) │   │ - 本地特征向量库          │  │
│  └──────────┬───────────┘   └────────────┬─────────────┘   └─────────────┬─────────────┘  │
└─────────────│────────────────────────────│───────────────────────────────│────────────────┘
              │                             │                               │
              │ (识别不确定时)               │ (离线单据同步)                │ (主数据/特征广播)
              ▼                             ▼                               ▼
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                 云端后端系统 (WMS Core Cloud)                             │
│  ┌──────────────────────┐   ┌──────────────────────────┐   ┌───────────────────────────┐  │
│  │  VLM 大模型服务      │   │  核心库存与账务引擎      │   │  主数据与特征管理         │  │
│  │ - Qwen2-VL / MiniCPM  │   │ - 批次与 FIFO 先进先出   │   │ - 中央向量数据库          │  │
│  │ - 结构化 OCR 抽取    │   │ - 实时库存台账 / 变动流水│   │ - 多级别包装规格配置      │  │
│  └──────────────────────┘   └──────────────────────────┘   └───────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、 核心业务逻辑与扩展性考量

### 2.1 多级包装与动态单位换算（Unit & Packaging Hierarchy）
- **基准单位（Base Unit）**：系统内部所有库存变动、台账统计与成本核算统一以**最小不可分割单位**（如“包”、“袋”、“市斤”）作为基准数据存储。
- **动态规格链（Packaging Chain）**：扩展支持任意层级包装（散包 $\rightarrow$ 中盒 $\rightarrow$ 大箱 $\rightarrow$ 托盘）。每个规格配置 `conversion_ratio`（如：1 大箱 = 5 盒 = 50 包）。
- **解耦设计**：AI 视觉特征直接绑定到具体的包装规格（`unit_id`），扫码识别出规格后，系统自动完成基准数量计算，前端展示可切换为任一包装单位。

### 2.2 批次与保质期追溯（Batch & Expiry / FIFO Management）
- **餐饮安全红线**：餐饮原材料对保质期极其敏感。入库识别时，VLM 或 OCR 自动抓取包装上的**生产日期/保质期**信息。
- **批次管理（Stock Batch）**：每次入库自动生成唯一批次号 `batch_no = {SKU_CODE}-{YYYYMMDD}-{随机码}`。
- **先进先出（FIFO）出库推荐**：出库时，系统根据视觉识别出的 SKU，自动提示库管员：“请优先调取 [A02 货架] 批次为 20260701 的原材料（剩余保质期 3 天）”。

### 2.3 货位管理与库位协同（Location Management）
- 仓库支持三级空间结构：`仓库 (Warehouse) -> 区域 (Zone) -> 货位/货架 (Location)`。
- 扫码识别原材料后，界面显示该 SKU 的**推荐存放货位**与当前各货位库存分布。

---

## 三、 高扩展性完整数据库 Schema 设计

系统数据库设计采用 **“端云同构、云端全量、端侧剪裁镜像”** 的设计策略：
- **服务端（中央数据库，如 PostgreSQL / MySQL + pgvector）**：拥有**全量 10 张表**的数据，负责跨门店全局台账、全量历史流水审计、中央特征库与大模型微调数据沉淀。
- **移动端（端侧数据库，如 SQLite + sqlite-vec）**：存储**当前仓库/门店的子集数据**，确保完全离线可用与毫秒级秒刷。网络恢复后通过轻量级 JSON 协议与服务端同步。

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             服务端全量数据库 (PostgreSQL)                        │
│ 包含: 全部 10 张表 (全局所有仓库 SKU、全量历史流水、全量向量特征库、全量批次台账)   │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                         │ 增量同步 (Sync Protocol)
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                         移动端剪裁数据库 (SQLite + sqlite-vec)                  │
│  ┌─────────────────────────┐  ┌─────────────────────────┐  ┌───────────────────┐  │
│  │ 本店 SKU与规格镜像      │  │ 端侧轻量特征向量索引    │  │ 本仓库存与批次    │  │
│  │ (raw_material_sku,      │  │ (material_feature_sample│  │ (stock_inventory, │  │
│  │  sku_packaging_unit)    │  │  vec_items)             │  │  stock_batch)     │  │
│  └─────────────────────────┘  └─────────────────────────┘  └───────────────────┘  │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │ 本地离线单据与待同步队列 (stock_order_header, stock_order_item)             │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 端云数据表分布矩阵

| 数据表名称 | 移动端 (SQLite) | 服务端 (PostgreSQL) | 数据同步策略与职责 |
| :--- | :---: | :---: | :--- |
| `warehouse_location` (货位表) | 局部镜像 | 全量 | 云端下发本仓库货位字典 |
| `raw_material_sku` (SKU主表) | 常用/本店镜像 | 全量 | 云端按门店/仓库订阅增量下发 |
| `sku_packaging_unit` (包装规格) | 常用/本店镜像 | 全量 | 随 SKU 一同同步下发 |
| `material_feature_sample` (特征表) | 常用/本店镜像 | 全量 | 仅下发常用规格特征向量（控制在 5 万条内） |
| `vec_items` (向量虚表) | 本地生成索引 | 云端 pgvector/Milvus | 端侧本地建索引检索；云端全量检索 |
| `stock_batch` (批次表) | 在库批次镜像 | 全量历史批次 | 端侧仅保留在库未消耗完批次 |
| `stock_inventory` (实时库存) | 本仓快照 | 全局全仓汇总 | 端侧只读/变动后本地预扣，最终以云端算账为准 |
| `stock_ledger_log` (流水日志) | 仅暂存未上传 | 全量不可篡改日志 | 端侧产生变动流水上传后清空/存档，云端永久保存 |
| `stock_order_header` (单据头) | 离线单据队列 | 全量单据 | 双向同步（离线创建上传，云端下发历史单） |
| `stock_order_item` (单据明细) | 离线单据明细 | 全量单据明细 | 双向同步 |

---

### 3.2 基础主数据与包装规格表 DDL

```sql
-- 1. 仓库与货位表
CREATE TABLE IF NOT EXISTS warehouse_location (
    location_id VARCHAR(64) PRIMARY KEY,
    warehouse_code VARCHAR(32) NOT NULL,       -- 仓库编码 (如: WH01 主库)
    zone_code VARCHAR(32) NOT NULL,            -- 区域 (如: COLD 冻库 / DRY 干货区)
    location_code VARCHAR(64) UNIQUE NOT NULL, -- 货位号 (如: A-01-02)
    location_name VARCHAR(128),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. 原材料标准 SKU 主表 (核心主数据)
CREATE TABLE IF NOT EXISTS raw_material_sku (
    sku_id VARCHAR(64) PRIMARY KEY,
    sku_code VARCHAR(64) UNIQUE NOT NULL,      -- SKU 编码 (全局唯一)
    sku_name VARCHAR(128) NOT NULL,             -- 商品标准名称 (如: 精品肥牛卷)
    category_name VARCHAR(64) NOT NULL,         -- 分类 (如: 肉类/冷冻品)
    base_unit VARCHAR(32) NOT NULL DEFAULT '包',-- 最小计数基准单位
    min_stock_warning DECIMAL(10, 2) DEFAULT 0, -- 安全库存下限预警
    shelf_life_days INT DEFAULT 0,              -- 标准保质期天数
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. SKU 多级包装规格表 (支持散包、中箱、大箱、托盘无限扩展)
CREATE TABLE IF NOT EXISTS sku_packaging_unit (
    unit_id VARCHAR(64) PRIMARY KEY,
    sku_id VARCHAR(64) NOT NULL,
    unit_name VARCHAR(32) NOT NULL,             -- 规格名称 (如: 散包 / 中箱 / 大箱)
    unit_type VARCHAR(20) NOT NULL,             -- 规格类型: BASE, MID, LARGE, PALLET
    conversion_ratio DECIMAL(10, 2) NOT NULL,   -- 对应 base_unit 的换算比例 (1, 10, 50)
    barcode VARCHAR(64),                        -- EAN/条形码/二维码 (如有)
    gross_weight_kg DECIMAL(8, 2),              -- 毛重(kg)
    length_cm DECIMAL(8, 2), width_cm DECIMAL(8, 2), height_cm DECIMAL(8, 2), -- 尺寸
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id) ON DELETE CASCADE
);
```

### 3.2 多模态 AI 特征向量表

```sql
-- 4. 多模态特征向量表 (支持一规格多角度/多形态 1:N 样本)
CREATE TABLE IF NOT EXISTS material_feature_sample (
    sample_id VARCHAR(64) PRIMARY KEY,
    unit_id VARCHAR(64) NOT NULL,               -- 关联包装规格
    sku_id VARCHAR(64) NOT NULL,                -- 关联 SKU
    angle_tag VARCHAR(32) DEFAULT 'FRONT',      -- 角度标记: FRONT(正面), SIDE(侧面), MARK(唛头)
    ocr_text_content TEXT,                      -- 历史抓取到的 OCR 关键文本
    vision_embedding_blob BLOB NOT NULL,      -- 视觉向量 (512维 Float32)
    text_embedding_blob BLOB NOT NULL,        -- 文本向量 (384维 Float32)
    sample_image_path TEXT,                   -- 本地/云端图片 URL
    is_cloud_synced TINYINT DEFAULT 0,          -- 云端同步状态
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (unit_id) REFERENCES sku_packaging_unit(unit_id) ON DELETE CASCADE
);

-- 5. sqlite-vec 端侧向量检索虚表
CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING vec0(
    sample_id TEXT PRIMARY KEY,
    fusion_embedding float[512] distance_metric=cosine
);
```

### 3.3 库存批次与台账流水表（库存核心）

```sql
-- 6. 库存批次表 (Batch Management & FIFO)
CREATE TABLE IF NOT EXISTS stock_batch (
    batch_id VARCHAR(64) PRIMARY KEY,
    batch_no VARCHAR(64) UNIQUE NOT NULL,      -- 批次号 (如: SKU001-20260729-01)
    sku_id VARCHAR(64) NOT NULL,
    production_date DATE,                       -- 生产日期 (VLM/OCR 提取)
    expiration_date DATE,                       -- 保质期截止日期
    supplier_name VARCHAR(128),                 -- 供应商名称
    inbound_price DECIMAL(10, 2),               -- 入库单价
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id)
);

-- 7. 实时库存台账汇总表 (按照 仓库+货位+SKU+批次 维度汇总)
CREATE TABLE IF NOT EXISTS stock_inventory (
    inventory_id VARCHAR(64) PRIMARY KEY,
    location_id VARCHAR(64) NOT NULL,           -- 货位 ID
    sku_id VARCHAR(64) NOT NULL,                -- SKU ID
    batch_id VARCHAR(64) NOT NULL,              -- 批次 ID
    qty_base_unit DECIMAL(12, 2) NOT NULL DEFAULT 0, -- 当前剩余总数量 (以 base_unit 计)
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(location_id, sku_id, batch_id),
    FOREIGN KEY (location_id) REFERENCES warehouse_location(location_id),
    FOREIGN KEY (sku_id) REFERENCES raw_material_sku(sku_id),
    FOREIGN KEY (batch_id) REFERENCES stock_batch(batch_id)
);

-- 8. 库存变动不可篡改流水日志 (Ledger Log)
CREATE TABLE IF NOT EXISTS stock_ledger_log (
    log_id VARCHAR(64) PRIMARY KEY,
    order_no VARCHAR(64) NOT NULL,              -- 关联单据号
    order_type VARCHAR(20) NOT NULL,            -- INBOUND(入库), OUTBOUND(出库), CHECK(盘点), TRANSFER(调拨)
    location_id VARCHAR(64) NOT NULL,
    sku_id VARCHAR(64) NOT NULL,
    batch_id VARCHAR(64) NOT NULL,
    unit_id VARCHAR(64) NOT NULL,               -- 操作时识别出/选择的包装规格
    operating_qty DECIMAL(10, 2) NOT NULL,      -- 操作规格数量 (例如 2 大箱)
    converted_base_qty DECIMAL(12, 2) NOT NULL, -- 换算后的基准数量 (例如 100 包)
    before_qty DECIMAL(12, 2) NOT NULL,         -- 变动前库存数量
    after_qty DECIMAL(12, 2) NOT NULL,          -- 变动后库存数量
    operator_user VARCHAR(64),                  -- 操作员工
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 3.4 业务单据头与明细表

```sql
-- 9. 出入库与盘点单据头表
CREATE TABLE IF NOT EXISTS stock_order_header (
    order_id VARCHAR(64) PRIMARY KEY,
    order_no VARCHAR(64) UNIQUE NOT NULL,      -- 单据编号 (如: IN202607290001)
    order_type VARCHAR(20) NOT NULL,            -- 单据类型: INBOUND, OUTBOUND, COUNT, TRANSFER
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT',-- 状态: DRAFT(草稿), SUBMITTED(已提交), AUDITED(已完成)
    warehouse_code VARCHAR(32) NOT NULL,
    operator_id VARCHAR(64),
    remark TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 10. 出入库与盘点单据明细表
CREATE TABLE IF NOT EXISTS stock_order_item (
    item_id VARCHAR(64) PRIMARY KEY,
    order_id VARCHAR(64) NOT NULL,
    sku_id VARCHAR(64) NOT NULL,
    unit_id VARCHAR(64) NOT NULL,               -- 识别出的规格 (如大箱)
    batch_id VARCHAR(64),
    scanned_qty DECIMAL(10, 2) NOT NULL,        -- 扫描记录数量 (如 1)
    conversion_ratio DECIMAL(10, 2) NOT NULL,   -- 此时的换算比例 (50)
    total_base_qty DECIMAL(12, 2) NOT NULL,     -- 最终换算基础数量 (50)
    recognition_mode VARCHAR(20),               -- 识别来源: EMBEDDING_LOCAL, VLM_CLOUD, MANUAL
    confidence_score FLOAT,                     -- 视觉识别置信度得分
    FOREIGN KEY (order_id) REFERENCES stock_order_header(order_id) ON DELETE CASCADE
);
```

---

## 四、 智能识别与业务流深度结合

### 4.1 端到端入库全流程

```
[移动端扫描包装] ──> 【智能识别引擎】 ──> 确定 sku_id 与 unit_id (如 大箱)
                           │
                           ├──> 抓取生产日期/保质期 ──> 自动生成/关联 stock_batch
                           │
                           ├──> 显示推荐货位 (如 冷库 A-01) ──> 确认入库数量 (如 2 大箱)
                           │
                           ▼
                  【生成入库明细项】 (单据写入 stock_order_item)
                           │
                           ▼
                  【原子更新库存与流水】 ──> 更新 stock_inventory & 插入 stock_ledger_log
```

### 4.2 离线优先同步协议（Offline Sync Engine）
1. **本地事务保证**：在断网环境下，App 生成 `order_id` 与 `ledger_log`，写入本地 SQLite，单据标记为 `PENDING_SYNC`。
2. **后向幂等同步**：恢复网络后，后台 Worker 提取 `PENDING_SYNC` 队列按时间序批量推送到云端 REST/gRPC API。
3. **主数据增量广播**：云端新增 SKU 或新增特征向量后，通过 Websocket / 增量 Sync 接口向手机终端推送补丁包（Delta Patch），保持移动端向量库最新。

---

## 五、 系统可扩展性设计原则

1. **识别算法可插拔（Algorithm Abstraction）**：
   通过定义统一的 `IRecognitionEngine` 接口，底层可随时自由替换为 TensorRT-LLM、MNN-VLM 或第三方云 API，业务层无感知。
2. **多单位平滑扩展（Infinite Unit Scales）**：
   新增“托盘/吨/桶”等规格时，只需在 `sku_packaging_unit` 增加一行记录并绑定参考特征，无需改动任何核心出入库代码。
3. **审计与防差错（Auditability）**：
   单据明细表中保留 `recognition_mode`（识别来源）与 `confidence_score`（置信度）。当人工修改了 AI 识别结果时，系统自动标记为“人工纠正样本”，可回传用于云端大模型的增量微调（LoRA Fine-tuning）。
