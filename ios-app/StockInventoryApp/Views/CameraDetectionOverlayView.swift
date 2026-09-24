//
//  CameraDetectionOverlayView.swift
//  StockInventoryApp · 相机取景器实时高科技目标检测框
//

import UIKit

/// 相机取景器实时目标物动态轮廓/检测框与准星视觉层
final class CameraDetectionOverlayView: UIView {
    private let boxContainerView = UIView()
    private let cornersLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let statusBadge = UILabel()

    /// 当前跟踪的目标物信息
    private(set) var currentROI: DetectedObjectROI?
    private var lastVideoBufferSize: CGSize?

    /// 标记是否处于激活显示状态
    private var isBoxVisible = false
    private var dismissTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        backgroundColor = .clear
        isUserInteractionEnabled = false

        boxContainerView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.08)
        boxContainerView.layer.cornerRadius = 10
        boxContainerView.clipsToBounds = false
        boxContainerView.alpha = 0
        addSubview(boxContainerView)

        // 边框描边
        borderLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.75).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1.8
        borderLayer.lineDashPattern = [6, 4]
        boxContainerView.layer.addSublayer(borderLayer)

        // 四角准星
        cornersLayer.strokeColor = UIColor.systemGreen.cgColor
        cornersLayer.fillColor = nil
        cornersLayer.lineWidth = 3.2
        cornersLayer.lineCap = .round
        boxContainerView.layer.addSublayer(cornersLayer)

        // 顶部“目标识别”标签
        statusBadge.font = .systemFont(ofSize: 11, weight: .bold)
        statusBadge.textColor = .white
        statusBadge.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.88)
        statusBadge.textAlignment = .center
        statusBadge.layer.cornerRadius = 6
        statusBadge.clipsToBounds = true
        statusBadge.alpha = 0
        addSubview(statusBadge)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let roi = currentROI {
            showBox(for: roi, videoBufferSize: lastVideoBufferSize, animated: false)
        }
    }

    /// 实时更新当前检测到的目标物体轮廓与边界（全自动，尺寸根据物料动态伸缩）
    func updateDetection(roi: DetectedObjectROI?, videoBufferSize: CGSize, animated: Bool = true) {
        dismissTimer?.invalidate()
        lastVideoBufferSize = videoBufferSize

        guard let target = roi, target.isValid else {
            // 短暂未检测到物体时，延迟 0.45 秒平滑淡出，防止丢帧闪烁
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                self?.hideBox(animated: animated)
            }
            return
        }

        currentROI = target
        showBox(for: target, videoBufferSize: videoBufferSize, animated: animated)
    }

    private func showBox(for roi: DetectedObjectROI, videoBufferSize: CGSize?, animated: Bool) {
        let targetFrame = viewFrame(for: roi.normalizedRect, videoBufferSize: videoBufferSize)
        guard targetFrame.width > 20, targetFrame.height > 20 else { return }

        // 根据来源生成标签文本
        let badgeText: String
        let percent = Int(roi.confidence * 100)
        switch roi.source {
        case "rectangle_contour":
            badgeText = "📦 包装箱 (\(percent)%)"
        case "objectness_saliency":
            badgeText = "🎯 目标物料 (\(percent)%)"
        case "attention_saliency":
            badgeText = "🔍 视觉焦点 (\(percent)%)"
        default:
            badgeText = "🎯 目标 (\(percent)%)"
        }
        statusBadge.text = badgeText

        // 像素级微小晃动死区抑制（静止时绝对不跳动）
        let currentFrame = boxContainerView.frame
        if isBoxVisible,
           abs(currentFrame.origin.x - targetFrame.origin.x) < 2.0,
           abs(currentFrame.origin.y - targetFrame.origin.y) < 2.0,
           abs(currentFrame.size.width - targetFrame.size.width) < 2.0,
           abs(currentFrame.size.height - targetFrame.size.height) < 2.0 {
            return
        }

        let duration = animated ? 0.08 : 0.0
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: {
                self.boxContainerView.frame = targetFrame
                self.boxContainerView.alpha = 1.0
                self.borderLayer.frame = self.boxContainerView.bounds
                self.cornersLayer.frame = self.boxContainerView.bounds
                self.updateCornerPaths(bounds: self.boxContainerView.bounds)

                // 标签悬浮在目标框上方居中
                let badgeWidth: CGFloat = 110
                let badgeHeight: CGFloat = 22
                let badgeX = targetFrame.midX - badgeWidth / 2
                let badgeY = max(targetFrame.minY - badgeHeight - 6, 50)
                self.statusBadge.frame = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
                self.statusBadge.alpha = 1.0
            }
        )

        isBoxVisible = true
    }

    private func hideBox(animated: Bool) {
        guard isBoxVisible else { return }
        isBoxVisible = false
        currentROI = nil

        let duration = animated ? 0.25 : 0.0
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            self.boxContainerView.alpha = 0
            self.statusBadge.alpha = 0
        }
    }

    /// 将归一化坐标经由 Aspect Fill 几何反投影映射为当前 View 内的实际精确 Frame
    private func viewFrame(for normalizedRect: CGRect, videoBufferSize: CGSize?) -> CGRect {
        let viewWidth = bounds.width
        let viewHeight = bounds.height
        guard viewWidth > 0, viewHeight > 0 else { return .zero }

        guard let bufferSize = videoBufferSize, bufferSize.width > 0, bufferSize.height > 0 else {
            return CGRect(
                x: normalizedRect.origin.x * viewWidth,
                y: normalizedRect.origin.y * viewHeight,
                width: normalizedRect.size.width * viewWidth,
                height: normalizedRect.size.height * viewHeight
            )
        }

        let videoWidth = bufferSize.width
        let videoHeight = bufferSize.height

        // .resizeAspectFill 几何映射换算
        let scale = max(viewWidth / videoWidth, viewHeight / videoHeight)
        let renderedWidth = videoWidth * scale
        let renderedHeight = videoHeight * scale
        let offsetX = (viewWidth - renderedWidth) / 2.0
        let offsetY = (viewHeight - renderedHeight) / 2.0

        let screenX = offsetX + normalizedRect.origin.x * renderedWidth
        let screenY = offsetY + normalizedRect.origin.y * renderedHeight
        let screenW = normalizedRect.size.width * renderedWidth
        let screenH = normalizedRect.size.height * renderedHeight

        return CGRect(x: screenX, y: screenY, width: screenW, height: screenH)
    }

    /// 绘制具有科技感的动态四角准星（随物体尺寸自适应长度）
    private func updateCornerPaths(bounds: CGRect) {
        let path = UIBezierPath()
        let cornerLen: CGFloat = min(min(bounds.width, bounds.height) * 0.2, 24)

        // 左上角
        path.move(to: CGPoint(x: 0, y: cornerLen))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: cornerLen, y: 0))

        // 右上角
        path.move(to: CGPoint(x: bounds.width - cornerLen, y: 0))
        path.addLine(to: CGPoint(x: bounds.width, y: 0))
        path.addLine(to: CGPoint(x: bounds.width, y: cornerLen))

        // 右下角
        path.move(to: CGPoint(x: bounds.width, y: bounds.height - cornerLen))
        path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        path.addLine(to: CGPoint(x: bounds.width - cornerLen, y: bounds.height))

        // 左下角
        path.move(to: CGPoint(x: cornerLen, y: bounds.height))
        path.addLine(to: CGPoint(x: 0, y: bounds.height))
        path.addLine(to: CGPoint(x: 0, y: bounds.height - cornerLen))

        cornersLayer.path = path.cgPath

        // 边框圆角矩形
        borderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 10).cgPath
    }
}
