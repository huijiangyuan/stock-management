//
//  AIRecognitionResultView.swift
//  库存管理 App · AI 识别结果富展示 Sheet
//
//  展示图片缩略图、置信度进度条、识别字段（名称/规格/生产日期/到期日期）、
//  本地 SKU 比对结果，并给出操作按钮区：确认入库出库 / 登记到材料库 / 手动选择 / 重拍。
//

import SwiftUI

struct AIRecognitionResultView: View {
    let result: RecognitionResult
    let imageData: Data
    /// 采纳识别结果并自动填表
    let onConfirm: () -> Void
    /// 引导登记新 SKU（传识别出的名称预填 SKUFormView）
    let onLearn: () -> Void
    /// 手动选择 SKU
    let onManual: () -> Void
    /// 重新拍照
    let onRetake: () -> Void

    @Environment(\.dismiss) private var dismiss

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
        UIImage(data: imageData)
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
                            Label("识别结果", systemImage: "text.viewfinder")
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.bottom, 2)
                            RecognitionFieldRow(label: "名称",
                                               value: result.recognizedName,
                                               fallback: "未识别")
                            Divider()
                            RecognitionFieldRow(label: "规格单位",
                                               value: result.packagingUnit?.unitName,
                                               fallback: result.recognizedName != nil ? "—" : "未识别")
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
                            Label("材料库比对", systemImage: "magnifyingglass.circle")
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.bottom, 2)
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
                                if let unit = result.packagingUnit {
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
                                    Image(systemName: "questionmark.circle.fill")
                                        .foregroundColor(.warning)
                                    Text(result.recognizedName != nil
                                         ? "未在材料库中找到「\(result.recognizedName!)」"
                                         : "材料库中无匹配记录")
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
                            // 未命中或低置信度：主操作 = 登记到材料库
                            PrimaryButton(title: result.recognizedName != nil
                                          ? "登记到材料库（已预填名称）"
                                          : "登记到材料库") {
                                onLearn()
                                dismiss()
                            }
                            if result.sku != nil {
                                // 低置信度但命中：仍可强制采纳
                                Button {
                                    onConfirm()
                                    dismiss()
                                } label: {
                                    Text("仍然采纳此结果")
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
