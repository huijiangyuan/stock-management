import SwiftUI
import SwiftData

/// 新增 / 编辑 SKU，并维护其多级包装规格。学习模式（扫到未知条码/AI 识别新品）也走此表单。
struct SKUFormView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    var editing: RawMaterialSKU?
    var initialBarcode: String? = nil
    /// AI 识别后预填的商品名称（新品登记快速通道）
    var initialName: String? = nil
    /// 保存成功后的回调，将新创建/修改的 SKU 回传给调用方
    var onSaved: ((RawMaterialSKU) -> Void)? = nil

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
    @State private var capturedImageData: Data? = nil
    @State private var aiBannerMsg: String? = nil
    @State private var showAiBanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section("AI 智能识别填表") {
                        HStack {
                            Button {
                                handleCameraTap()
                            } label: {
                                Label("📷 拍照 AI 填表", systemImage: "camera.viewfinder")
                                    .fontWeight(.medium)
                            }
                            Spacer()
                            Button {
                                activeSheet = .scanner
                            } label: {
                                Label("扫码录入", systemImage: "barcode.viewfinder")
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let msg = aiBannerMsg, showAiBanner {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(msg.contains("成功") ? .green : .orange)
                        }
                    }

                    Section("基础信息") {
                        TextField("商品编码（如 SKU-1001）", text: $skuCode)
                        TextField("商品名称（如 精品肥牛卷）", text: $skuName)
                        TextField("品类（如 肉类/冻品）", text: $categoryName)
                        TextField("基准单位", text: $baseUnit)
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
            .navigationTitle(editing == nil ? "新增原材料" : "编辑原材料")
            .toolbar {
                Button("取消") { dismiss() }
                Button("保存") { save(); dismiss() }.disabled(!canSave)
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .camera:
                    CameraCaptureView { data in
                        Task { @MainActor in
                            await runAiRecognize(data)
                        }
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
        }
    }

    private var canSave: Bool {
        !skuCode.isEmpty && !skuName.isEmpty && !units.isEmpty &&
        units.allSatisfy { !$0.unitName.isEmpty && Double($0.conversionRatio) != nil }
    }

    private func loadIfEditing() {
        guard let s = editing else {
            var base = PackagingUnitDraft(unitName: "散包", unitType: "BASE", conversionRatio: "1")
            if let bc = initialBarcode { base.barcode = bc }
            units = [base]
            // AI 识别新品登记：预填名称并自动生成预设 SKU 编码
            if let name = initialName { skuName = name }
            let randomCodeSuffix = String(format: "%04d", Int.random(in: 1000...9999))
            skuCode = "SKU-\(randomCodeSuffix)"
            return
        }
        skuCode = s.skuCode; skuName = s.skuName; categoryName = s.categoryName
        baseUnit = s.baseUnit; shelfLifeDays = "\(s.shelfLifeDays)"
        units = s.packagingUnits.map {
            PackagingUnitDraft(unitId: $0.unitId, unitName: $0.unitName, unitType: $0.unitType,
                               conversionRatio: "\($0.conversionRatio)", barcode: $0.barcode ?? "")
        }
    }

    private func save() {
        let ratio: Double = Double(shelfLifeDays) ?? 0
        let store = InventoryStore(context: ctx)

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
        try? ctx.save()
        if let img = capturedImageData {
            saveFeatureSample(image: img, sku: target, unit: target.packagingUnits.first, name: skuName)
        }
        _ = store
        onSaved?(target)
    }

    private func handleCameraTap() {
        let settings = VisionSettings.shared
        if OnDeviceVisionEngine.shared.onDeviceUsable || settings.cloudReady {
            activeSheet = .camera
            return
        }
        if ModelManager.shared.modelPresent {
            Task {
                await ModelManager.shared.ensureLoaded()
                activeSheet = .camera
            }
            return
        }
        aiBannerMsg = "⚠️ AI 识别未就绪：请先去「设置」下载端侧模型或配置云端 Key。"
        showAiBanner = true
    }

    @MainActor
    private func runAiRecognize(_ data: Data) async {
        aiBusy = true
        capturedImageData = data
        let prefer = VisionSettings.shared.preferOnDevice
        let cloudReady = VisionSettings.shared.cloudReady

        if prefer && !OnDeviceVisionEngine.shared.loadSuccess {
            await ModelManager.shared.ensureLoaded()
        }

        var result: RecognitionResult
        if prefer {
            if OnDeviceVisionEngine.shared.onDeviceUsable {
                result = await OnDeviceVisionEngine.shared.recognize(imageData: data)
            } else if cloudReady {
                result = await CloudVisionEngine().recognize(RecognitionInput(visionImage: data), context: ctx)
            } else {
                result = RecognitionResult(confidence: 0, mode: .vision, needsLearning: true, recognizedName: nil)
            }
        } else {
            if cloudReady {
                result = await CloudVisionEngine().recognize(RecognitionInput(visionImage: data), context: ctx)
            } else if OnDeviceVisionEngine.shared.onDeviceUsable {
                result = await OnDeviceVisionEngine.shared.recognize(imageData: data)
            } else {
                result = RecognitionResult(confidence: 0, mode: .vision, needsLearning: true, recognizedName: nil)
            }
        }
        aiBusy = false

        if let name = result.recognizedName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skuName = name
            if let exp = result.expirationDate, let prod = result.productionDate {
                let days = Calendar.current.dateComponents([.day], from: prod, to: exp).day ?? 0
                if days > 0 { shelfLifeDays = "\(days)" }
            }
            if let unit = result.packagingUnit {
                baseUnit = unit.unitName
            }
            aiBannerMsg = "✨ AI 识别成功：已自动为你预填商品名称「\(name)」！"
            showAiBanner = true
        } else {
            aiBannerMsg = "⚠️ AI 未能在图片中识出明确商品名称，请手动填写基础信息。"
            showAiBanner = true
        }
    }

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
}
