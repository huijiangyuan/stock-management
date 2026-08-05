import SwiftUI
import SwiftData

/// 出入库 / 盘点 单据创建。支持扫码（条码引擎）与手动两种识别来源，
/// 自动完成 多级包装 → 基准单位 换算，并按批次 FIFO 给出出库建议。
struct OrderCreateView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    var presetSKU: RawMaterialSKU?
    var presetType: String

    @State private var orderType: String
    @State private var selectedSKU: RawMaterialSKU?
    @State private var selectedUnit: PackagingUnit?
    @State private var qtyText = "1"
    @State private var location = "默认货位"

    enum ActiveSheet: Identifiable {
        case skuPicker
        case scanner
        case camera
        case learn(barcode: String?, prefillName: String?)
        case visionResult(VisionRecognitionOutcome)
        case settings
        case modelManager

        var id: String {
            switch self {
            case .skuPicker: return "skuPicker"
            case .scanner: return "scanner"
            case .camera: return "camera"
            case .learn(let b, let n): return "learn_\(b ?? "")_\(n ?? "")"
            case .visionResult: return "visionResult"
            case .settings: return "settings"
            case .modelManager: return "modelManager"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var deferredSheet: ActiveSheet?
    @State private var pendingCameraData: Data?
    @State private var lastMode: RecognitionMode = .manual

    // AI 视觉识别相关
    @State private var visionBusy = false
    @State private var latestVisionOutcome: VisionRecognitionOutcome?
    @State private var didSaveLatestVisionSample = false
    @State private var visionResultName: String?
    @State private var visionConfidence: Double = 0
    // 提交失败 Alert
    @State private var showSubmitErrorAlert = false
    @State private var submitErrorMessage = ""

    // 入库批次字段
    @State private var batchNo = ""
    @State private var productionDate = Date()
    @State private var expirationDate = Date()
    @State private var supplier = ""
    @State private var inboundPrice = ""
    // 出库/盘点批次选择
    @State private var selectedBatch: StockBatch?
    @State private var showFIFOAlert = false
    @State private var pendingBatch: StockBatch? = nil
    @State private var fifoOverrideNote: String? = nil

    init(presetSKU: RawMaterialSKU? = nil, presetType: String = "INBOUND") {
        self.presetSKU = presetSKU
        self.presetType = presetType
        _orderType = State(initialValue: presetType)
        _selectedSKU = State(initialValue: presetSKU)
        _selectedUnit = State(initialValue: presetSKU?.packagingUnits.first)
    }

    private var totalBase: Double {
        guard let u = selectedUnit, let q = Double(qtyText) else { return 0 }
        return q * u.conversionRatio
    }

    private var inStockBatches: [StockBatch] {
        guard let sku = selectedSKU else { return [] }
        return InventoryStore(context: ctx).fifoBatches(for: sku)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section("单据类型") {
                        Picker("类型", selection: $orderType) {
                            Text("入库").tag("INBOUND")
                            Text("出库").tag("OUTBOUND")
                            Text("盘点").tag("CHECK")
                        }
                        .pickerStyle(.segmented)
                        .disabled(presetSKU != nil)
                    }

                    Section("商品物料") {
                        if let sku = selectedSKU {
                            HStack {
                                Text(sku.skuName).font(.headline)
                                Spacer()
                                Button("重选") { activeSheet = .skuPicker }
                            }
                            if let u = selectedUnit {
                                Picker("规格", selection: $selectedUnit) {
                                    ForEach(sku.packagingUnits) { unit in
                                        Text("\(unit.unitName) ×\(AppFormatters.fmt(unit.conversionRatio))").tag(unit as PackagingUnit?)
                                    }
                                }
                            }
                        } else {
                            Button("选择商品物料 / 扫码") { activeSheet = .skuPicker }
                        }
                        
                        // ── AI 识别引擎健康状态指示 ──────────────────────
                        aiEngineStatusBadge
                        
                        // ── 端侧模型自动加载中动态 Banner ───────────────
                        ModelAutoLoadingBannerView()

                        Button { activeSheet = .scanner } label: {
                            Label("扫码识别", systemImage: "barcode.viewfinder")
                        }
                        Button { handleAIRecognizeTap() } label: {
                            Label("AI 识别（拍照）", systemImage: "camera.viewfinder")
                        }
                        .disabled(visionBusy)
                    }

                    if selectedSKU != nil {
                        Section("数量") {
                            HStack {
                                TextField("操作数量", text: $qtyText).keyboardType(.decimalPad)
                                if let u = selectedUnit {
                                    Text(u.unitName).foregroundColor(.secondary)
                                }
                            }
                            if let u = selectedUnit {
                                Text("换算为 \(AppFormatters.fmt(totalBase)) \(selectedSKU?.baseUnit ?? "包")")
                                    .font(.subheadline).foregroundColor(.secondary)
                            }
                        }

                        Section("货位") {
                            TextField("货位名称", text: $location)
                        }

                        if orderType == "INBOUND" {
                            Section("新建批次") {
                                TextField("批次号（留空自动生成）", text: $batchNo)
                                DatePicker("生产日期", selection: $productionDate, displayedComponents: .date)
                                DatePicker("到期日期", selection: $expirationDate, displayedComponents: .date)
                                TextField("供应商", text: $supplier)
                                TextField("入库单价", text: $inboundPrice).keyboardType(.decimalPad)
                            }
                        } else {
                            batchSection
                        }
                    }
                }

                if visionBusy {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.3)
                        Text("AI 正在分析识别图片，请稍候...")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    .padding(24)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 12)
                }
            }
            .navigationTitle(title)
            .toolbar {
                Button("取消") { dismiss() }
                Button("生成单据") { submit() }.disabled(!canSubmit)
            }
            .sheet(item: $activeSheet, onDismiss: handleSheetDismissed) { sheet in
                switch sheet {
                case .skuPicker:
                    SKUPickerSheet(selected: $selectedSKU)
                case .scanner:
                    BarcodeScannerView { code in
                        handleScanned(code)
                    }
                case .camera:
                    CameraCaptureView { data in
                        pendingCameraData = data
                    }
                case .learn(let barcode, let prefillName):
                    SKUFormView(initialBarcode: barcode, initialName: prefillName, onSaved: { newSKU in
                        selectedSKU = newSKU
                        selectedUnit = newSKU.packagingUnits.first
                    })
                case .visionResult(let outcome):
                    AIRecognitionResultView(
                        outcome: outcome,
                        onConfirm: {
                            applyVisionConfirmed(outcome)
                        },
                        onQuickAdd: { name in
                            quickAddSKUAndSelect(name: name, outcome: outcome)
                        },
                        onLearn: {
                            deferredSheet = .learn(barcode: nil, prefillName: outcome.result.recognizedName)
                        },
                        onManual: {
                            deferredSheet = .skuPicker
                        },
                        onRetake: {
                            deferredSheet = .camera
                        }
                    )
                case .settings:
                    NavigationStack {
                        SettingsView()
                    }
                case .modelManager:
                    NavigationStack {
                        ModelManagerView()
                    }
                }
            }
            .alert("FIFO 覆盖确认", isPresented: $showFIFOAlert) {
                Button("取消", role: .cancel) {
                    selectedBatch = inStockBatches.first
                    pendingBatch = nil
                }
                Button("确认覆盖") {
                    if let chosen = pendingBatch {
                        selectedBatch = chosen
                        let skipped = inStockBatches.prefix(while: { $0.batchId != chosen.batchId })
                                              .map { $0.batchNo }
                        let iso = ISO8601DateFormatter().string(from: Date())
                        fifoOverrideNote = "FIFO覆盖：跳过批次[\(skipped.joined(separator: ","))]，时间\(iso)"
                    }
                    pendingBatch = nil
                }
            } message: {
                let skipped = inStockBatches.prefix(while: { $0.batchId != (pendingBatch?.batchId ?? "") })
                                          .map { $0.batchNo }
                Text("所选批次并非最早可出库批次，将跳过更早批次：\(skipped.joined(separator: "、"))。是否仍按该批次出库？")
            }
            .alert("单据生成失败", isPresented: $showSubmitErrorAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(submitErrorMessage)
            }
        }
    }

    private var title: String {
        orderType == "INBOUND" ? "入库单" : orderType == "OUTBOUND" ? "出库单" : "盘点单"
    }

    private var canSubmit: Bool {
        guard let _ = selectedSKU, let _ = selectedUnit, Double(qtyText) ?? 0 > 0 else { return false }
        if orderType != "INBOUND" && inStockBatches.isEmpty { return false }
        return true
    }

    /// 出库 / 盘点时按 FIFO 选择批次：最早批次可直接选，非最早需二次确认覆盖。
    private var batchSection: some View {
        Section("选择批次（FIFO 优先）") {
            if inStockBatches.isEmpty {
                Text("无可用批次").foregroundColor(.secondary)
            } else {
                ForEach(inStockBatches) { batch in
                    Button {
                        if inStockBatches.first?.batchId == batch.batchId {
                            selectedBatch = batch
                        } else {
                            pendingBatch = batch
                            showFIFOAlert = true
                        }
                    } label: {
                        BatchPickRow(batch: batch,
                                     selected: selectedBatch?.batchId == batch.batchId,
                                     isEarliest: inStockBatches.first?.batchId == batch.batchId)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func handleScanned(_ code: String) {
        Task { @MainActor in
            lastMode = .barcode
            let result = await BarcodeEngine().recognize(RecognitionInput(barcode: code), context: ctx)
            if let sku = result.sku {
                selectedSKU = sku
                selectedUnit = result.packagingUnit ?? sku.packagingUnits.first
            } else {
                activeSheet = .learn(barcode: code, prefillName: nil)
            }
        }
    }

    private func handleAIRecognizeTap() {
        activeSheet = .camera
    }

    private func submit() {
        guard let sku = selectedSKU, let unit = selectedUnit,
              let qty = Double(qtyText), qty > 0 else { return }
        let store = InventoryStore(context: ctx)

        var batch: StockBatch? = nil
        if orderType == "INBOUND" {
            let newBatch = StockBatch(batchNo: batchNo.isEmpty ? Self.autoBatchNo(sku) : batchNo,
                               productionDate: productionDate, expirationDate: expirationDate,
                               supplierName: supplier.isEmpty ? nil : supplier,
                               inboundPrice: Double(inboundPrice), sku: sku)
            ctx.insert(newBatch)
            batch = newBatch
        } else {
            batch = selectedBatch
        }

        if lastMode == .vision, !didSaveLatestVisionSample, let outcome = latestVisionOutcome {
            didSaveLatestVisionSample = saveFeatureSample(
                outcome: outcome,
                sku: sku,
                unit: unit,
                name: visionResultName
            )
        }
        let line = InventoryStore.OrderLine(sku: sku, unit: unit, batch: batch,
                                            operatingQty: qty, conversionRatio: unit.conversionRatio,
                                            mode: lastMode, note: fifoOverrideNote)
        do {
            try store.processOrder(type: orderType, lines: [line], location: location)
            dismiss()
        } catch {
            submitErrorMessage = "单据处理失败：\(error.localizedDescription)"
            showSubmitErrorAlert = true
        }
    }

    private var aiEngineStatusBadge: some View {
        HStack(spacing: 6) {
            let onDevice = OnDeviceVisionEngine.shared.onDeviceUsable
            let loaded = ModelManager.shared.loaded
            let present = ModelManager.shared.modelPresent
            let cloud = VisionSettings.shared.cloudReady

            if onDevice && loaded {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("AI：图片向量优先 · MiniCPM-V 兜底已就绪").font(.caption).foregroundColor(.secondary)
            } else if present && !loaded {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("AI：图片向量已就绪 · MiniCPM-V 按需加载").font(.caption).foregroundColor(.secondary)
            } else if cloud {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
                Text("AI：图片向量优先 · 云端 VLM 兜底").font(.caption).foregroundColor(.secondary)
            } else {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("AI：图片向量已就绪 · 未命中时手动确认").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - AI 视觉识别流程（三档：端侧优先 → 云端兜底 → 引导手动）

    @MainActor
    private func handleSheetDismissed() {
        if let data = pendingCameraData {
            pendingCameraData = nil
            Task { @MainActor in
                await runVisionAndTransition(data)
            }
            return
        }
        if let next = deferredSheet {
            deferredSheet = nil
            activeSheet = next
        }
    }

    @MainActor
    private func runVisionAndTransition(_ data: Data) async {
        guard !visionBusy else {
            AppLogger.shared.log(level: .warning, category: .ai, message: "已忽略重复的图片识别请求")
            return
        }
        visionBusy = true
        defer { visionBusy = false }
        do {
            let outcome = try await VisionRecognitionPipeline(context: ctx).recognize(rawImageData: data)
            latestVisionOutcome = outcome
            didSaveLatestVisionSample = false
            activeSheet = .visionResult(outcome)
        } catch {
            AppLogger.shared.log(
                level: .error,
                category: .ai,
                message: "AI 图片识别流程失败",
                details: error.localizedDescription
            )
        }
    }

    @MainActor
    private func quickAddSKUAndSelect(name: String, outcome: VisionRecognitionOutcome) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let skuName = cleanName.isEmpty ? "未命名新材料" : cleanName
        let randomSuffix = String(format: "%04d", Int.random(in: 1000...9999))
        let skuCode = "SKU-\(randomSuffix)"
        
        let newSKU = RawMaterialSKU(
            skuCode: skuCode,
            skuName: skuName,
            categoryName: "默认品类",
            baseUnit: "包",
            shelfLifeDays: 30
        )
        ctx.insert(newSKU)

        let baseUnitObj = PackagingUnit(
            unitName: "散包",
            unitType: "BASE",
            conversionRatio: 1.0,
            sku: newSKU
        )
        ctx.insert(baseUnitObj)
        do {
            try ctx.save()
        } catch {
            AppLogger.shared.log(level: .error, category: .store, message: "快捷创建商品保存失败", details: error.localizedDescription)
            return
        }

        // 绑定该采样的特征向量
        didSaveLatestVisionSample = saveFeatureSample(
            outcome: outcome,
            sku: newSKU,
            unit: baseUnitObj,
            name: skuName
        )

        // 自动设为当前单据在办材料
        selectedSKU = newSKU
        selectedUnit = baseUnitObj
        lastMode = .vision

        AppLogger.shared.log(level: .info, category: .ai, message: "一键快捷创建商品底库: 「\(skuName)」(\(skuCode))")
        ToastManager.shared.show(message: "⚡️ 已快捷创建商品并自动选定", details: "商品名称: \(skuName)", tone: .success)
    }

    @MainActor
    private func applyVisionConfirmed(_ outcome: VisionRecognitionOutcome) {
        let result = outcome.result
        if let sku = result.sku {
            selectedSKU = sku
            selectedUnit = result.packagingUnit ?? sku.packagingUnits.first
            if let pd = result.productionDate { productionDate = pd }
            if let ed = result.expirationDate { expirationDate = ed }
            lastMode = .vision
            visionResultName = result.recognizedName
            visionConfidence = result.confidence
            latestVisionOutcome = outcome
        }
    }

    /// 识别确认入库后沉淀特征样本（为后续端侧向量比对攒数据）
    private func saveFeatureSample(
        outcome: VisionRecognitionOutcome,
        sku: RawMaterialSKU,
        unit: PackagingUnit?,
        name: String?
    ) -> Bool {
        guard let embedding = outcome.embedding else {
            AppLogger.shared.log(
                level: .error,
                category: .store,
                message: "未保存图片特征样本",
                details: "本次识别没有生成有效的 MobileCLIP 向量"
            )
            return false
        }
        do {
            try FeatureRepository(context: ctx).saveSample(
                image: outcome.processedImage,
                embedding: embedding,
                ocrText: name ?? sku.skuName,
                unit: unit,
                sku: sku
            )
            return true
        } catch {
            AppLogger.shared.log(level: .error, category: .store, message: "图片特征样本保存失败", details: error.localizedDescription)
            return false
        }
    }

    static func autoBatchNo(_ sku: RawMaterialSKU) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let r = Int.random(in: 1...99)
        return "\(sku.skuCode)-\(df.string(from: Date()))-\(String(format: "%02d", r))"
    }
}

struct BatchPickRow: View {
    let batch: StockBatch
    let selected: Bool
    let isEarliest: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(batch.batchNo).font(.subheadline)
                    if isEarliest {
                        Text("最早")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.warning)
                            .clipShape(Capsule())
                    }
                }
                if let exp = batch.expirationDate {
                    Text("到期 \(AppFormatters.date.string(from: exp))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(.brand) }
        }
    }
}

/// SKU 选择浮层（可搜索）
struct SKUPickerSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RawMaterialSKU.skuName) private var skus: [RawMaterialSKU]
    @State private var search = ""
    @Binding var selected: RawMaterialSKU?

    var body: some View {
        NavigationStack {
            List {
                ForEach(skus.filter {
                    search.isEmpty || $0.skuName.localizedCaseInsensitiveContains(search)
                        || $0.skuCode.localizedCaseInsensitiveContains(search)
                }) { sku in
                    Button { selected = sku; dismiss() } label: { SKURow(sku: sku) }
                }
            }
            .searchable(text: $search, prompt: "搜索名称或编码")
            .navigationTitle("选择商品物料")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}
