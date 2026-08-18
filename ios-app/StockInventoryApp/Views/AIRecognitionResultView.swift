//
//  AIRecognitionResultView.swift
//  库存管理 App · AI 识别结果富展示 Sheet
//
//  展示图片缩略图、置信度进度条、识别字段（名称/规格/生产日期/到期日期）、
//  本地 SKU 比对结果，并给出操作按钮区：确认入库出库 / 登记到材料库 / 手动选择 / 重拍。
//

import SwiftUI

struct AIRecognitionResultView: View {
    let outcome: VisionRecognitionOutcome
    /// 采纳识别结果并自动填表
    let onConfirm: () -> Void
    /// 一键快捷创建材料底库并选定为当前单据材料（包含完整识别预填信息）
    let onQuickAdd: (SKUPrefillDraft) -> Void
    /// 引导登记新 SKU（带回完整 AI 识别预填草稿，打开表单直接填好）
    let onLearn: (SKUPrefillDraft) -> Void
    /// 手动选择 SKU
    let onManual: () -> Void
    /// 重新拍照
    let onRetake: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputName: String = ""

    init(outcome: VisionRecognitionOutcome,
         onConfirm: @escaping () -> Void,
         onQuickAdd: @escaping (SKUPrefillDraft) -> Void,
         onLearn: @escaping (SKUPrefillDraft) -> Void,
         onManual: @escaping () -> Void,
         onRetake: @escaping () -> Void) {
        self.outcome = outcome
        self.onConfirm = onConfirm
        self.onQuickAdd = onQuickAdd
        self.onLearn = onLearn
        self.onManual = onManual
        self.onRetake = onRetake
        _inputName = State(initialValue: outcome.result.recognizedName ?? "")
    }

    private var result: RecognitionResult { outcome.result }

    private var currentDraft: SKUPrefillDraft {
        let targetName = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let validName = targetName.isEmpty ? (result.recognizedName ?? "新商品物料") : targetName
        return SKUPrefillDraft(
            skuName: validName,
            categoryName: result.displayCategoryName ?? "默认品类",
            baseUnit: result.displayUnitName ?? "个",
            shelfLifeDays: result.displayShelfLifeDays ?? 0,
            barcode: result.recognizedBarcode,
            productionDate: result.productionDate,
            expirationDate: result.expirationDate,
            visionOutcome: outcome
        )
    }

    // 置信度颜色
    private var confidenceColor: Color {
        if result.confidence >= 0.8 { return .success }
        if result.confidence >= 0.6 { return .warning }
        return .danger
    }

    private var confidenceLabel: String {
        if result.confidence >= 0.8 { return "识别可信" }
        if result.confidence >= 0.6 { return "需要确认" }
        if result.confidence > 0    { return "识别不确定" }
        return "未识别"
    }

    private var image: UIImage? {
        UIImage(data: outcome.processedImage.jpegData)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.s4) {
                    // ── 图片缩略图 ──────────────────────────────────
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.standard, style: .continuous))
                            .padding(.horizontal, AppSpacing.s3)
                    }

                    // ── 置信度进度条 ────────────────────────────────
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.s1) {
                            HStack {
                                Image(systemName: confidenceColor == .success
                                      ? "checkmark.seal.fill"
                                      : confidenceColor == .warning
                                      ? "exclamationmark.triangle.fill"
                                      : "xmark.seal.fill")
                                    .foregroundColor(confidenceColor)
                                Text("识别置信度").font(.subheadline).fontWeight(.semibold)
                                Spacer()
                                Text("\(Int(result.confidence * 100))%  · \(confidenceLabel)")
                                    .font(.subheadline)
                                    .foregroundColor(confidenceColor)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.surface)
                                        .frame(height: 8)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(confidenceColor)
                                        .frame(width: geo.size.width * result.confidence, height: 8)
                                        .animation(.easeOut(duration: 0.4), value: result.confidence)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    .padding(.horizontal, AppSpacing.s3)

                    // ── 识别字段卡 ──────────────────────────────────
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.s2) {
                            Label("AI 识别详情", systemImage: "sparkles")
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.bottom, 2)
                            RecognitionFieldRow(label: "品名",
                                               value: result.recognizedName,
                                               fallback: "未识别")
                            Divider()
                            RecognitionFieldRow(label: "规格单位",
                                               value: result.displayUnitName,
                                               fallback: "—")
                            Divider()
                            RecognitionFieldRow(label: "品类",
                                               value: result.displayCategoryName,
                                               fallback: "—")
                            if let days = result.displayShelfLifeDays, days > 0 {
                                Divider()
                                RecognitionFieldRow(label: "标准保质期",
                                                   value: "\(days) 天",
                                                   fallback: "—")
                            }
                            Divider()
                            RecognitionFieldRow(
                                label: "生产日期",
                                value: result.productionDate.map { AppFormatters.date.string(from: $0) },
                                fallback: "—")
                            Divider()
                            RecognitionFieldRow(
                                label: "到期日期",
                                value: result.expirationDate.map { AppFormatters.date.string(from: $0) },
                                fallback: "—")
                        }
                    }
                    .padding(.horizontal, AppSpacing.s3)

                    // ── 本地 SKU 比对结果 ────────────────────────────
                    AppCard {
                        VStack(alignment: .leading, spacing: AppSpacing.s2) {
                            Label("商品库比对", systemImage: "magnifyingglass.circle")
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.bottom, 2)
                            HStack {
                                Text("识别来源")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(outcome.source.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.brand)
                            }
                            Text("诊断编号：\(outcome.recognitionID)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                            if !outcome.matches.isEmpty {
                                Divider()
                                Text("图片向量 Top \(outcome.matches.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ForEach(outcome.matches.indices, id: \.self) { index in
                                    let match = outcome.matches[index]
                                    if let candidate = match.sample.sku {
                                        HStack(spacing: AppSpacing.s1) {
                                            Text("\(index + 1)")
                                                .font(.caption2.bold())
                                                .foregroundColor(.white)
                                                .frame(width: 20, height: 20)
                                                .background(Color.brand)
                                                .clipShape(Circle())
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(candidate.skuName)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                Text(candidate.skuCode)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Text("\(Int(match.similarity * 100))%")
                                                .font(.caption.monospacedDigit())
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                Divider()
                            }
                            if let sku = result.sku {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sku.skuName).font(.body).fontWeight(.medium)
                                        Text("编码: \(sku.skuCode)  ·  \(sku.categoryName)")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.success)
                                        .font(.title3)
                                }
                                if let unit = result.packagingUnit ?? sku.packagingUnits.first {
                                    HStack {
                                        Text("匹配规格")
                                            .font(.caption).foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(unit.unitName)  ×\(AppFormatters.fmt(unit.conversionRatio)) \(sku.baseUnit)")
                                            .font(.caption).fontWeight(.medium)
                                    }
                                }
                            } else {
                                HStack(spacing: AppSpacing.s1) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.brand)
                                    Text(result.recognizedName != nil
                                         ? "检测到新品「\(result.recognizedName!)」，可一键建库入库"
                                         : "未在商品库中找到匹配记录")
                                        .font(.subheadline).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.s3)

                    // ── 操作按钮区 ──────────────────────────────────
                    VStack(spacing: AppSpacing.s2) {
                        if result.sku != nil && result.confidence >= 0.6 {
                            // 高置信度命中：主操作 = 确认
                            PrimaryButton(title: "确认，自动填表") {
                                onConfirm()
                                dismiss()
                            }
                        } else {
                            // 未命中（新品）或低置信度：主操作区
                            VStack(spacing: AppSpacing.s2) {
                                let draft = currentDraft
                                Button {
                                    onQuickAdd(draft)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "bolt.fill")
                                        Text("⚡️ 一键快捷登记新品「\(draft.skuName)」并填表")
                                            .fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(Color.brand)
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                Button {
                                    onLearn(draft)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.pencil")
                                        Text("AI 自动预填并登记到商品库...")
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.surface)
                                    .foregroundColor(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            if result.sku != nil {
                                // 低置信度但命中：仍可强制采纳
                                Button {
                                    onConfirm()
                                    dismiss()
                                } label: {
                                    Text("仍然采纳此匹配结果")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(Color.warning.opacity(0.15))
                                        .foregroundColor(.warning)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }

                        HStack(spacing: AppSpacing.s2) {
                            Button {
                                onManual()
                                dismiss()
                            } label: {
                                Label("手动选择", systemImage: "list.bullet")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.surface)
                                    .foregroundColor(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            Button {
                                onRetake()
                                dismiss()
                            } label: {
                                Label("重拍", systemImage: "arrow.counterclockwise.camera")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.surface)
                                    .foregroundColor(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.s3)
                    .padding(.bottom, AppSpacing.s4)
                }
                .padding(.top, AppSpacing.s3)
            }
            .navigationTitle("AI 识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 识别字段行

private struct RecognitionFieldRow: View {
    let label: String
    let value: String?
    let fallback: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Spacer()
            Text(value ?? fallback)
                .font(.subheadline)
                .fontWeight(value != nil ? .medium : .regular)
                .foregroundColor(value != nil ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
