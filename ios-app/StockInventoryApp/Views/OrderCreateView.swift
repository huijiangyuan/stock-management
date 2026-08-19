import SwiftUI
import SwiftData
import UIKit

/// 出入库 / 盘点 业务操作界面。
/// 支持 AI 拍照多模态极速识别，匹配成功直接自动填表；
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
        case camera
        case learn(prefillName: String?, draft: SKUPrefillDraft? = nil)
        case visionResult(VisionRecognitionOutcome)

        var id: String {
            switch self {
            case .skuPicker: return "skuPicker"
            case .camera: return "camera"
            case .learn(let n, let d): return "learn_\(n ?? "")_\(d?.skuName ?? "")"
            case .visionResult: return "visionResult"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var deferredSheet: ActiveSheet?
    @State private var pendingCameraData: Data?
    @State private var recognitionTask: Task<Void, Never>?
    @State private var lastMode: RecognitionMode = .manual

    // AI 视觉识别相关
    @State private var visionBusy = false
    @State private var latestVisionOutcome: VisionRecognitionOutcome?
    @State private var didSaveLatestVisionSample = false
    @State private var visionResultName: String?
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

    /// 当前选定物料在指定货位/批次下的实时账面基准库存量
    private var currentBookBaseQty: Double {
        guard let sku = selectedSKU else { return 0 }
        let store = InventoryStore(context: ctx)
        return store.totalQty(location: location, sku: sku, batch: orderType == "CHECK" ? selectedBatch : nil)
    }

    /// 盘点差异：实盘换算量 - 账面原基准量
    private var checkDifferenceBaseQty: Double {
        totalBase - currentBookBaseQty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        VStack(spacing: 8) {
                            Button {
                                activeSheet = .camera
                            } label: {
                                HStack {
                                    Image(systemName: "camera.viewfinder")
                                    Text("📷 拍照 AI 智能识别")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.brand)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            // ── 端侧 AI 模型自动加载中动态动画提示 Banner ────
                            ModelAutoLoadingBannerView()

                            aiEngineStatusBadge
                        }
                        .padding(.vertical, 4)
                    }

                    Section("业务操作类型") {
                        Picker("类型", selection: $orderType) {
                            Text("入库").tag("INBOUND")
                            Text("出库").tag("OUTBOUND")
                            Text("盘点").tag("CHECK")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: orderType) { _, _ in
                            selectedBatch = inStockBatches.first
                        }
                    }

                    Section("商品物料与规格") {
                        Button {
                            activeSheet = .skuPicker
                        } label: {
                            HStack {
                                Text("选择商品")
                                    .foregroundColor(.primary)
                                Spacer()
                                if let sku = selectedSKU {
                                    Text("\(sku.skuName) (\(sku.skuCode))")
                                        .foregroundColor(.brand)
                                        .fontWeight(.medium)
                                } else {
                                    Text("点击选择商品物料")
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let sku = selectedSKU {
                            if !sku.packagingUnits.isEmpty {
                                Picker("包装规格", selection: $selectedUnit) {
                                    ForEach(sku.packagingUnits, id: \.unitId) { (u: PackagingUnit) in
                                        Text("\(u.unitName) (×\(AppFormatters.fmt(u.conversionRatio)) \(sku.baseUnit))")
                                            .tag(Optional(u))
                                    }
                                }
                            }
                            HStack {
                                Text(orderType == "CHECK" ? "实盘数量" : "操作数量")
                                TextField("数量", text: $qtyText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text(selectedUnit?.unitName ?? sku.baseUnit)
                                    .foregroundColor(.secondary)
                            }
                            if let u = selectedUnit, u.conversionRatio != 1.0 {
                                HStack {
                                    Text("折算基准量")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("= \(AppFormatters.fmt(totalBase)) \(sku.baseUnit)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.brand)
                                }
                            }

                            // 盘点模式专属实时差异计算卡片
                            if orderType == "CHECK" {
                                VStack(alignment: .leading, spacing: 6) {
                                    Divider()
                                    HStack {
                                        Text("账面库存（系统）")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(AppFormatters.fmt(currentBookBaseQty)) \(sku.baseUnit)")
                                            .font(.caption.bold())
                                    }
                                    HStack {
                                        Text("实盘核准量")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(AppFormatters.fmt(totalBase)) \(sku.baseUnit)")
                                            .font(.caption.bold())
                                    }
                                    HStack {
                                        Text("盘点盈亏差异")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        if checkDifferenceBaseQty > 0 {
                                            Text("盘盈 +\(AppFormatters.fmt(checkDifferenceBaseQty)) \(sku.baseUnit)")
                                                .font(.caption.bold())
                                                .foregroundColor(.success)
                                        } else if checkDifferenceBaseQty < 0 {
                                            Text("盘亏 \(AppFormatters.fmt(checkDifferenceBaseQty)) \(sku.baseUnit)")
                                                .font(.caption.bold())
                                                .foregroundColor(.danger)
                                        } else {
                                            Text("账实相符 (无差异)")
                                                .font(.caption.bold())
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section("存放库位") {
                        TextField("库位 / 货架（如 A-01-02）", text: $location)
                    }

                    Section(orderType == "INBOUND" ? "入库批次与保质期" : orderType == "OUTBOUND" ? "批次出库（FIFO 优先）" : "盘点批次选择") {
                        if orderType == "INBOUND" {
                            TextField("批次号（留空自动生成）", text: $batchNo)
                            DatePicker("生产日期", selection: $productionDate, displayedComponents: .date)
                            DatePicker("到期日期", selection: $expirationDate, displayedComponents: .date)
                            TextField("供应商（选填）", text: $supplier)
                            TextField("入库单价（选填）", text: $inboundPrice).keyboardType(.decimalPad)
                        } else {
                            batchSection
                        }
                    }

                    Section {
                        VStack(spacing: 8) {
                            Button {
                                submit()
                            } label: {
                                HStack {
                                    Image(systemName: submitIcon)
                                    Text(submitButtonTitle)
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(canSubmit ? submitButtonColor : Color.gray.opacity(0.3))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSubmit)

                            Text(submitButtonHint)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 4)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitButtonTitle) { submit() }
                        .disabled(!canSubmit)
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $activeSheet, onDismiss: handleSheetDismissed) { sheet in
                switch sheet {
                case .skuPicker:
                    SKUPickerSheet(selected: $selectedSKU)
                case .camera:
                    CameraCaptureView { data in
                        pendingCameraData = data
                    }
                case .learn(let prefillName, let draft):
                    SKUFormView(
                        initialBarcode: draft?.barcode,
                        initialName: prefillName,
                        initialDraft: draft,
                        onSaved: { newSKU in
                            applyNewSKUAndPrefillOrder(newSKU, from: draft)
                        }
                    )
                case .visionResult(let outcome):
                    AIRecognitionResultView(
                        outcome: outcome,
                        onConfirm: {
                            applyVisionConfirmed(outcome)
                        },
                        onQuickAdd: { draft in
                            quickAddSKUAndSelect(draft: draft)
                        },
                        onLearn: { draft in
                            deferredSheet = .learn(prefillName: draft.skuName, draft: draft)
                        },
                        onManual: {
                            deferredSheet = .skuPicker
                        },
                        onRetake: {
                            deferredSheet = .camera
                        }
                    )
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
            .alert("操作失败", isPresented: $showSubmitErrorAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(submitErrorMessage)
            }
            .onDisappear {
                recognitionTask?.cancel()
                recognitionTask = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                recognitionTask?.cancel()
                OnDeviceVisionEngine.shared.cancelCurrentRecognition(reason: "系统发出内存警告")
                AppLogger.shared.log(
                    level: .error,
                    category: .ai,
                    message: "系统内存不足，已取消本次图片识别"
                )
            }
        }
    }

    private var title: String {
        orderType == "INBOUND" ? "商品入库" : orderType == "OUTBOUND" ? "商品出库" : "库存盘点"
    }

    private var submitButtonTitle: String {
        orderType == "INBOUND" ? "确认入库" : orderType == "OUTBOUND" ? "确认出库" : "确认盘点"
    }

    private var submitIcon: String {
        orderType == "INBOUND" ? "arrow.down.circle.fill" : orderType == "OUTBOUND" ? "arrow.up.circle.fill" : "checklist"
    }

    private var submitButtonColor: Color {
        orderType == "INBOUND" ? .success : orderType == "OUTBOUND" ? .brand : .warning
    }

    private var submitButtonHint: String {
        orderType == "INBOUND"
            ? "点击后将增加物理库存、登记批次并记录入库流水单据"
            : orderType == "OUTBOUND"
            ? "点击后将按 FIFO 扣减批次库存并记录出库流水单据"
            : "点击后将以实盘数据强制校准台账，并记录盘盈盘亏单据"
    }

    private var canSubmit: Bool {
        guard let _ = selectedSKU, let _ = selectedUnit, Double(qtyText) ?? 0 > 0 else { return false }
        if orderType != "INBOUND" && inStockBatches.isEmpty { return false }
        return true
    }

    /// 出库 / 盘点时按 FIFO 选择批次：最早批次可直接选，非最早需二次确认覆盖。
    private var batchSection: some View {
        Section(orderType == "OUTBOUND" ? "选择出库批次（FIFO 优先）" : "选择盘点所属批次") {
            if inStockBatches.isEmpty {
                Text("当前无在库批次").foregroundColor(.secondary)
            } else {
                ForEach(inStockBatches) { batch in
                    Button {
                        if inStockBatches.first?.batchId == batch.batchId || orderType == "CHECK" {
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
                                            mode: lastMode, note: fifoOverrideNote,
                                            originalBaseQty: orderType == "CHECK" ? currentBookBaseQty : nil,
                                            differenceBaseQty: orderType == "CHECK" ? checkDifferenceBaseQty : nil)
        do {
            try store.processOrder(type: orderType, lines: [line], location: location)
            let actionName = orderType == "INBOUND" ? "入库" : orderType == "OUTBOUND" ? "出库" : "盘点"
            ToastManager.shared.show(message: "✅ \(actionName)成功", details: "商品「\(sku.skuName)」· \(AppFormatters.fmt(totalBase))\(sku.baseUnit)", tone: .success)
            dismiss()
        } catch {
            submitErrorMessage = "业务处理失败：\(error.localizedDescription)"
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
                Text("AI：图片向量优先 · MiniCPM-V 兜底就绪").font(.caption).foregroundColor(.secondary)
            } else if present && !loaded {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("AI：图片向量就绪 · MiniCPM-V 按需加载").font(.caption).foregroundColor(.secondary)
            } else if cloud {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
                Text("AI：图片向量优先 · 云端 VLM 兜底").font(.caption).foregroundColor(.secondary)
            } else {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("AI：图片向量已就绪").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - AI 视觉识别流程（自动填表无需二次点击确认）

    @MainActor
    private func handleSheetDismissed() {
        if let data = pendingCameraData {
            pendingCameraData = nil
            recognitionTask?.cancel()
            recognitionTask = Task { @MainActor in
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

            // ⚡️ 核心无缝流转：如果高置信度命中了已有商品，直接自动填入表单，无需用户在结果页多点一次确认！
            if let sku = outcome.result.sku, outcome.result.confidence >= 0.6 {
                applyVisionConfirmed(outcome)
                let unitName = selectedUnit?.unitName ?? sku.baseUnit
                AppLogger.shared.log(level: .info, category: .ai, message: "AI 识别高置信度命中「\(sku.skuName)」，已直接自动填表")
                ToastManager.shared.show(
                    message: "✨ 已自动匹配「\(sku.skuName)」并填入表单",
                    details: "规格「\(unitName)」· 批次及到期日已就绪",
                    tone: .success
                )
            } else {
                // 未匹配到或低置信度：弹出新品建库与引导调整结果页
                activeSheet = .visionResult(outcome)
            }
        } catch is CancellationError {
            AppLogger.shared.log(level: .info, category: .ai, message: "AI 图片识别已取消")
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
    private func quickAddSKUAndSelect(draft: SKUPrefillDraft) {
        let cleanName = draft.skuName.trimmingCharacters(in: .whitespacesAndNewlines)
        let skuName = cleanName.isEmpty ? "未命名新材料" : cleanName
        let randomSuffix = String(format: "%04d", Int.random(in: 1000...9999))
        let skuCode = "SKU-\(randomSuffix)"
        let categoryName = draft.categoryName.isEmpty ? "默认品类" : draft.categoryName
        let baseUnit = draft.baseUnit.isEmpty ? "个" : draft.baseUnit
        let shelfLife = draft.shelfLifeDays

        let newSKU = RawMaterialSKU(
            skuCode: skuCode,
            skuName: skuName,
            categoryName: categoryName,
            baseUnit: baseUnit,
            shelfLifeDays: shelfLife
        )
        ctx.insert(newSKU)

        let baseUnitObj = PackagingUnit(
            unitName: baseUnit,
            unitType: "BASE",
            conversionRatio: 1.0,
            barcode: draft.barcode,
            sku: newSKU
        )
        ctx.insert(baseUnitObj)

        var selectedTargetUnit = baseUnitObj
        if let pkgName = draft.packagingUnitName, !pkgName.isEmpty, let ratio = draft.conversionRatio, ratio > 1.0 {
            let pkgUnitObj = PackagingUnit(
                unitName: pkgName,
                unitType: ratio >= 20 ? "LARGE" : "MID",
                conversionRatio: ratio,
                sku: newSKU
            )
            ctx.insert(pkgUnitObj)
            selectedTargetUnit = pkgUnitObj
        }

        do {
            try ctx.save()
        } catch {
            AppLogger.shared.log(level: .error, category: .store, message: "快捷创建商品保存失败", details: error.localizedDescription)
            return
        }

        if let outcome = draft.visionOutcome {
            didSaveLatestVisionSample = saveFeatureSample(
                outcome: outcome,
                sku: newSKU,
                unit: selectedTargetUnit,
                name: skuName
            )
            latestVisionOutcome = outcome
        }

        // 自动设为当前单据在办材料并完整预填所有单据字段
        selectedSKU = newSKU
        selectedUnit = selectedTargetUnit
        lastMode = .vision
        visionResultName = newSKU.skuName
        if let pd = draft.productionDate { productionDate = pd }
        if let ed = draft.expirationDate { expirationDate = ed }
        if batchNo.isEmpty { batchNo = Self.autoBatchNo(newSKU) }

        AppLogger.shared.log(level: .info, category: .ai, message: "一键快捷创建商品底库并自动填表: 「\(skuName)」(\(skuCode))")
        ToastManager.shared.show(message: "⚡️ 已快捷建库并自动填表", details: "商品「\(skuName)」· 批次及日期已填入", tone: .success)
    }

    @MainActor
    private func applyNewSKUAndPrefillOrder(_ newSKU: RawMaterialSKU, from draft: SKUPrefillDraft?) {
        selectedSKU = newSKU
        selectedUnit = newSKU.packagingUnits.first
        lastMode = .vision
        visionResultName = newSKU.skuName
        if let draft = draft {
            if let pd = draft.productionDate { productionDate = pd }
            if let ed = draft.expirationDate { expirationDate = ed }
            if batchNo.isEmpty { batchNo = Self.autoBatchNo(newSKU) }
            if let outcome = draft.visionOutcome {
                latestVisionOutcome = outcome
            }
        } else if let outcome = latestVisionOutcome {
            if let pd = outcome.result.productionDate { productionDate = pd }
            if let ed = outcome.result.expirationDate { expirationDate = ed }
            if batchNo.isEmpty { batchNo = Self.autoBatchNo(newSKU) }
        } else {
            if batchNo.isEmpty { batchNo = Self.autoBatchNo(newSKU) }
        }
    }

    @MainActor
    private func applyVisionConfirmed(_ outcome: VisionRecognitionOutcome) {
        let result = outcome.result
        if let sku = result.sku {
            selectedSKU = sku
            selectedUnit = result.packagingUnit ?? sku.packagingUnits.first
            if let pd = result.productionDate { productionDate = pd }
            if let ed = result.expirationDate { expirationDate = ed }
            if batchNo.isEmpty { batchNo = Self.autoBatchNo(sku) }
            lastMode = .vision
            visionResultName = result.recognizedName
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
                    Button { selected = sku; dismiss() } label: { SKUCatalogRow(sku: sku) }
                }
            }
            .searchable(text: $search, prompt: "搜索名称或编码")
            .navigationTitle("选择商品物料")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}
