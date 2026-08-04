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
        case visionResult(RecognitionResult, Data)
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
    @State private var lastMode: RecognitionMode = .manual

    // AI 视觉识别相关
    @State private var visionBusy = false
    @State private var visionImageData: Data?
    @State private var visionResultName: String?
    @State private var visionConfidence: Double = 0
    @State private var visionMessage: String?
    @State private var showVisionMsg = false

    // 前置检查 Alert
    @State private var showModelLoadGuide = false
    @State private var showModelDownloadGuide = false

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

                    Section("原材料") {
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
                            Button("选择原材料 / 扫码") { activeSheet = .skuPicker }
                        }
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
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .skuPicker:
                    SKUPickerSheet(selected: $selectedSKU)
                case .scanner:
                    BarcodeScannerView { code in
                        activeSheet = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            handleScanned(code)
                        }
                    }
                case .camera:
                    CameraCaptureView { data in
                        activeSheet = nil
                        visionBusy = true
                        Task { @MainActor in
                            // 400ms 延迟等待相机 Sheet 的 UIKit 关闭动画完全结束，彻底避免 UIKit 弹窗冲突崩溃
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            await runVision(data)
                        }
                    }
                case .learn(let barcode, let prefillName):
                    SKUFormView(initialBarcode: barcode, initialName: prefillName)
                case .visionResult(let result, let data):
                    AIRecognitionResultView(
                        result: result,
                        imageData: data,
                        onConfirm: {
                            applyVisionConfirmed(result)
                        },
                        onLearn: {
                            activeSheet = .learn(barcode: nil, prefillName: result.recognizedName)
                        },
                        onManual: {
                            activeSheet = .skuPicker
                        },
                        onRetake: {
                            activeSheet = .camera
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
            .alert("模型未加载", isPresented: $showModelLoadGuide) {
                Button("前往设置加载模型", role: .none) {
                    activeSheet = .modelManager
                }
                Button("尝试使用云端识别") {
                    if VisionSettings.shared.cloudReady {
                        activeSheet = .camera
                    } else {
                        activeSheet = .settings
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("端侧 MiniCPM-V 4.6 模型已下载但尚未加载。请前往「设置 -> 端侧 AI 模型」完成加载；或配置云端 VLM API Key 使用云端识别。")
            }
            .alert("AI 识别未就绪", isPresented: $showModelDownloadGuide) {
                Button("前往设置", role: .none) {
                    activeSheet = .settings
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("尚未准备好 AI 识别：端侧模型未下载，云端 VLM 也未配置 API Key。可前往「设置」下载端侧模型或配置云端 API Key。")
            }
            .alert("提示", isPresented: $showVisionMsg) {
                Button("前往设置", role: .none) {
                    activeSheet = .settings
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(visionMessage ?? "")
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
        let settings = VisionSettings.shared
        // 可用：端侧已就绪 or 云端配置了 Key
        if OnDeviceVisionEngine.shared.onDeviceUsable || settings.cloudReady {
            activeSheet = .camera
            return
        }
        // 模型已下载但未加载
        if ModelManager.shared.modelPresent {
            showModelLoadGuide = true
            return
        }
        // 完全未下载且云端未配置
        showModelDownloadGuide = true
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

        if lastMode == .vision, let img = visionImageData {
            saveFeatureSample(image: img, sku: sku, unit: unit, name: visionResultName)
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

    // MARK: - AI 视觉识别流程（三档：端侧优先 → 云端兜底 → 引导手动）

    @MainActor
    private func runVision(_ data: Data) async {
        visionBusy = true
        visionImageData = data
        let rawResult = await resolveAndRecognize(data)
        visionBusy = false

        let processedResult = processVisionResult(rawResult)
        if processedResult.confidence > 0 || processedResult.recognizedName != nil || processedResult.sku != nil {
            activeSheet = .visionResult(processedResult, data)
        } else {
            let extra = OnDeviceVisionEngine.shared.unavailableReason.isEmpty
                ? ""
                : "\n（\(OnDeviceVisionEngine.shared.unavailableReason)）"
            visionMessage = "未能识别出有效信息：请确认端侧模型已加载，或在「设置」中配置云端 VLM。\(extra)"
            showVisionMsg = true
        }
    }

    /// 按设置解析可用引擎：端侧优先（或云端不可用时）走本地 MiniCPM-V 4.6；
    /// 否则回退云端 VLM；两者皆不可用时给出引导，绝不阻塞用户。
    @MainActor
    private func resolveAndRecognize(_ data: Data) async -> RecognitionResult {
        let prefer = VisionSettings.shared.preferOnDevice
        let cloudReady = VisionSettings.shared.cloudReady

        if prefer && !OnDeviceVisionEngine.shared.loadSuccess {
            await ModelManager.shared.ensureLoaded()
        }
        let onDevice = OnDeviceVisionEngine.shared.onDeviceUsable

        if prefer {
            if onDevice { return await OnDeviceVisionEngine.shared.recognize(imageData: data) }
            if cloudReady { return await CloudVisionEngine().recognize(RecognitionInput(visionImage: data), context: ctx) }
        } else {
            if cloudReady { return await CloudVisionEngine().recognize(RecognitionInput(visionImage: data), context: ctx) }
            if onDevice { return await OnDeviceVisionEngine.shared.recognize(imageData: data) }
        }

        return RecognitionResult(confidence: 0, mode: .vision, needsLearning: true, recognizedName: nil)
    }

    private func processVisionResult(_ rawResult: RecognitionResult) -> RecognitionResult {
        var res = rawResult
        if res.sku == nil, let name = res.recognizedName {
            if let matched = matchSKU(by: name) {
                res = RecognitionResult(
                    sku: matched,
                    packagingUnit: matched.packagingUnits.first,
                    confidence: res.confidence,
                    mode: res.mode,
                    needsLearning: res.needsLearning,
                    recognizedName: res.recognizedName,
                    productionDate: res.productionDate,
                    expirationDate: res.expirationDate
                )
            } else if let localMatch = LocalFeatureEngine.searchBestMatch(ocrText: name, context: ctx) {
                let sku = localMatch.sample.sku
                res = RecognitionResult(
                    sku: sku,
                    packagingUnit: localMatch.sample.unit ?? sku?.packagingUnits.first,
                    confidence: max(res.confidence, Double(localMatch.similarity)),
                    mode: res.mode,
                    needsLearning: localMatch.similarity < 0.65,
                    recognizedName: name,
                    productionDate: res.productionDate,
                    expirationDate: res.expirationDate
                )
            }
        }
        return res
    }

    @MainActor
    private func applyVisionConfirmed(_ result: RecognitionResult) {
        if let sku = result.sku {
            selectedSKU = sku
            selectedUnit = result.packagingUnit ?? sku.packagingUnits.first
            if let pd = result.productionDate { productionDate = pd }
            if let ed = result.expirationDate { expirationDate = ed }
            lastMode = .vision
            visionResultName = result.recognizedName
            visionConfidence = result.confidence
        }
    }

    /// 按识别出的名称模糊匹配本地原材料（名称互含即命中）。
    private func matchSKU(by name: String) -> RawMaterialSKU? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let all = (try? ctx.fetch(FetchDescriptor<RawMaterialSKU>())) ?? []
        return all.first { sku in
            sku.skuName.localizedCaseInsensitiveContains(q) ||
            q.localizedCaseInsensitiveContains(sku.skuName)
        }
    }

    /// 识别确认入库后沉淀特征样本（为后续端侧向量比对攒数据）
    private func saveFeatureSample(image: Data, sku: RawMaterialSKU, unit: PackagingUnit?, name: String?) {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feature_samples", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        try? image.write(to: path)

        let text = name ?? sku.skuName
        let textEmbeddingVec = LocalFeatureEngine.generateTextEmbedding(text)
        let textData = LocalFeatureEngine.toData(textEmbeddingVec)

        let sample = FeatureSample(angleTag: "FRONT", ocrTextContent: text,
                                   sampleImagePath: path.path, unit: unit, sku: sku)
        sample.textEmbedding = textData
        ctx.insert(sample)
        try? ctx.save()
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
            .navigationTitle("选择原材料")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}
