import SwiftUI
import SwiftData
import UIKit

/// 新增 / 编辑 SKU，并维护其多级包装规格。学习模式（扫到未知条码/AI 识别新品）也走此表单。
struct SKUFormView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    var editing: RawMaterialSKU?
    var initialBarcode: String? = nil
    /// AI 识别后预填的商品名称（新品登记快速通道）
    var initialName: String? = nil
    /// AI 识别或外部传入的完整新品预填草稿
    var initialDraft: SKUPrefillDraft? = nil
    /// 保存成功后的回调，将新创建/修改的 SKU 回传给调用方
    var onSaved: ((RawMaterialSKU) -> Void)? = nil

    @State private var skuCode = ""
    @State private var skuName = ""
    @State private var categoryName = ""
    @State private var baseUnit = "包"
    @State private var shelfLifeDays = "0"
    @State private var units: [PackagingUnitDraft] = []

    struct PackagingUnitDraft: Identifiable {
        var id = UUID().uuidString
        var unitId: String? = nil
        var unitName: String
        var unitType: String
        var conversionRatio: String
        var barcode: String = ""
    }

    enum FormSheet: Identifiable {
        case camera
        case scanner
        var id: String {
            switch self {
            case .camera: return "camera"
            case .scanner: return "scanner"
            }
        }
    }

    @State private var activeSheet: FormSheet? = nil
    @State private var aiBusy = false
    @State private var pendingCameraData: Data? = nil
    @State private var capturedOutcome: VisionRecognitionOutcome? = nil
    @State private var recognitionTask: Task<Void, Never>? = nil
    @State private var aiBannerMsg: String? = nil
    @State private var showAiBanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        VStack(spacing: 10) {
                            HStack {
                                Label("AI 拍照 / 扫码智能填表", systemImage: "sparkles")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.brand)
                                Spacer()
                            }
                            
                            HStack(spacing: 12) {
                                Button {
                                    handleCameraTap()
                                } label: {
                                    HStack {
                                        Image(systemName: "camera.viewfinder")
                                        Text("📷 拍照 AI 填表")
                                            .fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(Color.brand)
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    activeSheet = .scanner
                                } label: {
                                    HStack {
                                        Image(systemName: "barcode.viewfinder")
                                        Text("扫码录入")
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(Color.surface)
                                    .foregroundColor(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // ── 端侧 AI 模型自动加载中动态动画提示 Banner ────
                            ModelAutoLoadingBannerView()
                            
                            if let msg = aiBannerMsg, showAiBanner {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(msg.contains("成功") || msg.contains("就绪") ? .green : .orange)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("基础信息") {
                        TextField("商品编码（如 SKU-1001）", text: $skuCode)
                        TextField("商品名称（如 蓝牙耳机 / 特级红酒 / 肥牛卷）", text: $skuName)
                        TextField("品类（如 数码 / 饮料 / 肉类 / 配件）", text: $categoryName)
                        TextField("基准单位（如 个/包/瓶）", text: $baseUnit)
                        TextField("标准保质期（天）", text: $shelfLifeDays)
                            .keyboardType(.numberPad)
                    }
                    Section("多级包装规格") {
                        ForEach($units) { $u in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField("规格名（散包/中箱/大箱）", text: $u.unitName)
                                    Picker("类型", selection: $u.unitType) {
                                        Text("BASE").tag("BASE")
                                        Text("MID").tag("MID")
                                        Text("LARGE").tag("LARGE")
                                        Text("PALLET").tag("PALLET")
                                    }
                                    .frame(width: 110)
                                }
                                HStack {
                                    TextField("换算系数（×基准单位）", text: $u.conversionRatio)
                                        .keyboardType(.decimalPad)
                                    TextField("条码（可选）", text: $u.barcode)
                                }
                            }
                        }
                        .onDelete { units.remove(atOffsets: $0) }
                        Button("添加规格") {
                            units.append(PackagingUnitDraft(unitName: "", unitType: "BASE", conversionRatio: "1"))
                        }
                    }
                }

                if aiBusy {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().scaleEffect(1.2)
                        Text("AI 正在分析识别图片...").font(.subheadline).fontWeight(.medium)
                    }
                    .padding(20)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .navigationTitle(editing == nil ? "新增商品物料" : "编辑商品物料")
            .toolbar {
                Button("取消") { dismiss() }
                Button("保存") {
                    if save() { dismiss() }
                }
                .disabled(!canSave)
            }
            .sheet(item: $activeSheet, onDismiss: handleSheetDismissed) { sheet in
                switch sheet {
                case .camera:
                    CameraCaptureView { data in
                        pendingCameraData = data
                    }
                case .scanner:
                    BarcodeScannerView { code in
                        if !units.isEmpty {
                            units[0].barcode = code
                        }
                        aiBannerMsg = "已扫描填充条码：\(code)"
                        showAiBanner = true
                    }
                }
            }
            .onAppear(perform: loadIfEditing)
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
                    message: "系统内存不足，已取消商品图片识别"
                )
            }
        }
    }

    private var canSave: Bool {
        !skuCode.isEmpty && !skuName.isEmpty && !units.isEmpty &&
        units.allSatisfy { !$0.unitName.isEmpty && Double($0.conversionRatio) != nil }
    }

    private func loadIfEditing() {
        guard let s = editing else {
            let randomCodeSuffix = String(format: "%04d", Int.random(in: 1000...9999))
            skuCode = "SKU-\(randomCodeSuffix)"

            if let draft = initialDraft {
                skuName = draft.skuName
                categoryName = draft.categoryName
                baseUnit = draft.baseUnit
                shelfLifeDays = draft.shelfLifeDays > 0 ? "\(draft.shelfLifeDays)" : "0"
                let unitName = draft.baseUnit.isEmpty ? "散包" : draft.baseUnit
                units = [PackagingUnitDraft(unitName: unitName, unitType: "BASE", conversionRatio: "1", barcode: draft.barcode ?? "")]
                capturedOutcome = draft.visionOutcome
                aiBannerMsg = "✨ AI 识别预填已就绪：商品名称「\(draft.skuName)」及品类、单位、保质期已自动填入！"
                showAiBanner = true
                return
            }

            var base = PackagingUnitDraft(unitName: "散包", unitType: "BASE", conversionRatio: "1")
            if let bc = initialBarcode { base.barcode = bc }
            units = [base]
            if let name = initialName { skuName = name }
            return
        }
        skuCode = s.skuCode; skuName = s.skuName; categoryName = s.categoryName
        baseUnit = s.baseUnit; shelfLifeDays = "\(s.shelfLifeDays)"
        units = s.packagingUnits.map {
            PackagingUnitDraft(unitId: $0.unitId, unitName: $0.unitName, unitType: $0.unitType,
                               conversionRatio: "\($0.conversionRatio)", barcode: $0.barcode ?? "")
        }
    }

    private func save() -> Bool {
        let ratio: Double = Double(shelfLifeDays) ?? 0

        let target: RawMaterialSKU
        if let s = editing {
            s.skuCode = skuCode; s.skuName = skuName; s.categoryName = categoryName
            s.baseUnit = baseUnit; s.shelfLifeDays = Int(ratio)
            target = s
        } else {
            target = RawMaterialSKU(skuCode: skuCode, skuName: skuName,
                                    categoryName: categoryName, baseUnit: baseUnit,
                                    shelfLifeDays: Int(ratio))
            ctx.insert(target)
        }

        // 同步包装规格（按 unitId 命中等幂）
        let existingIds = Set(target.packagingUnits.map { $0.unitId })
        for u in units {
            guard let cr = Double(u.conversionRatio) else { continue }
            if let id = u.unitId, existingIds.contains(id),
               let exist = target.packagingUnits.first(where: { $0.unitId == id }) {
                exist.unitName = u.unitName; exist.unitType = u.unitType
                exist.conversionRatio = cr; exist.barcode = u.barcode.isEmpty ? nil : u.barcode
            } else {
                let pu = PackagingUnit(unitName: u.unitName, unitType: u.unitType,
                                       conversionRatio: cr, barcode: u.barcode.isEmpty ? nil : u.barcode,
                                       sku: target)
                ctx.insert(pu)
            }
        }
        do {
            try ctx.save()
        } catch {
            AppLogger.shared.log(level: .error, category: .store, message: "商品资料保存失败", details: error.localizedDescription)
            return false
        }
        if let outcome = capturedOutcome {
            saveFeatureSample(outcome: outcome, sku: target, unit: target.packagingUnits.first, name: skuName)
        }
        onSaved?(target)
        return true
    }

    private func handleCameraTap() {
        activeSheet = .camera
    }

    @MainActor
    private func handleSheetDismissed() {
        guard let data = pendingCameraData else { return }
        pendingCameraData = nil
        recognitionTask?.cancel()
        recognitionTask = Task { @MainActor in
            await runAiRecognize(data)
        }
    }

    @MainActor
    private func runAiRecognize(_ data: Data) async {
        guard !aiBusy else {
            AppLogger.shared.log(level: .warning, category: .ai, message: "已忽略重复的商品图片识别请求")
            return
        }
        aiBusy = true
        defer { aiBusy = false }

        let outcome: VisionRecognitionOutcome
        do {
            outcome = try await VisionRecognitionPipeline(context: ctx).extractAttributesForNewSKU(rawImageData: data)
            capturedOutcome = outcome
        } catch is CancellationError {
            AppLogger.shared.log(level: .info, category: .ai, message: "商品图片识别已取消")
            return
        } catch {
            AppLogger.shared.log(level: .error, category: .ai, message: "商品图片识别流程失败", details: error.localizedDescription)
            return
        }
        let result = outcome.result

        var filledFields: [String] = []

        if let name = result.recognizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            skuName = name
            filledFields.append("品名「\(name)」")
        }
        if let cat = result.displayCategoryName?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
            categoryName = cat
            filledFields.append("品类「\(cat)」")
        }
        if let unit = result.displayUnitName?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty {
            baseUnit = unit
            if !units.isEmpty {
                units[0].unitName = unit
            } else {
                units = [PackagingUnitDraft(unitName: unit, unitType: "BASE", conversionRatio: "1")]
            }
            filledFields.append("单位「\(unit)」")
        }
        if let days = result.displayShelfLifeDays, days > 0 {
            shelfLifeDays = "\(days)"
            filledFields.append("保质期 \(days) 天")
        }
        if let barcode = result.recognizedBarcode?.trimmingCharacters(in: .whitespacesAndNewlines), !barcode.isEmpty {
            if !units.isEmpty {
                units[0].barcode = barcode
            }
            filledFields.append("条码")
        }

        if !filledFields.isEmpty {
            let summary = filledFields.joined(separator: " · ")
            aiBannerMsg = "✨ AI 智能填表成功：已自动填充 \(summary)"
            showAiBanner = true
            AppLogger.shared.log(level: .info, category: .ai, message: "AI 拍照自动完整填表成功: \(summary)")
            ToastManager.shared.show(message: "✨ AI 智能填表成功", details: summary, tone: .success)
        } else {
            aiBannerMsg = "⚠️ AI 未能在图片中识出明确商品名称，请手动填写基础信息。"
            showAiBanner = true
            AppLogger.shared.log(level: .warning, category: .ai, message: "AI 拍照未能识出商品名称")
            ToastManager.shared.show(message: "未识出明确商品名称", details: "请在下方手动输入商品信息", tone: .warning)
        }
    }

    private func saveFeatureSample(
        outcome: VisionRecognitionOutcome,
        sku: RawMaterialSKU,
        unit: PackagingUnit?,
        name: String?
    ) {
        guard let embedding = outcome.embedding else {
            AppLogger.shared.log(
                level: .error,
                category: .store,
                message: "未保存商品图片特征",
                details: "本次识别没有生成有效的 MobileCLIP 向量"
            )
            return
        }
        do {
            try FeatureRepository(context: ctx).saveSample(
                image: outcome.processedImage,
                embedding: embedding,
                ocrText: name ?? sku.skuName,
                unit: unit,
                sku: sku
            )
        } catch {
            AppLogger.shared.log(level: .error, category: .store, message: "商品图片特征保存失败", details: error.localizedDescription)
        }
    }
}
