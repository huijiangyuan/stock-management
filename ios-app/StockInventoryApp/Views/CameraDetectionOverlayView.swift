//
//  CameraDetectionOverlayView.swift
//  StockInventoryApp · 相机取景器实时高科技目标检测框
//

import UIKit

/// 相机取景器实时目标检测框与准星视觉层
final class CameraDetectionOverlayView: UIView {
    private let boxContainerView = UIView()
    private let cornersLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let statusBadge = UILabel()

    /// 当前展示的归一化 ROI
    private(set) var currentNormalizedRect: CGRect?

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
        boxContainerView.layer.cornerRadius = 12
        boxContainerView.clipsToBounds = false
        boxContainerView.alpha = 0
        addSubview(boxContainerView)

        // 边框描边
        borderLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.65).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        boxContainerView.layer.addSublayer(borderLayer)

        // 四角准星
        cornersLayer.strokeColor = UIColor.systemGreen.cgColor
        cornersLayer.fillColor = nil
        cornersLayer.lineWidth = 3.0
        cornersLayer.lineCap = .round
        boxContainerView.layer.addSublayer(cornersLayer)

        // 顶部“目标锁定”标签
        statusBadge.text = "🎯 目标锁定"
        statusBadge.font = .systemFont(ofSize: 11, weight: .bold)
        statusBadge.textColor = .white
        statusBadge.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85)
        statusBadge.textAlignment = .center
        statusBadge.layer.cornerRadius = 6
        statusBadge.clipsToBounds = true
        statusBadge.alpha = 0
        addSubview(statusBadge)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let rect = currentNormalizedRect {
            showBox(for: rect, animated: false)
        }
    }

    /// 更新当前目标物检测框（传入归一化坐标：0.0~1.0）
    func updateROI(normalizedRect: CGRect?, animated: Bool = true) {
        dismissTimer?.invalidate()

        guard let rect = normalizedRect, rect.width > 0.05, rect.height > 0.05 else {
            // 若未检测到目标，延时 0.6 秒淡出，避免短暂丢帧闪烁
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                self?.hideBox(animated: animated)
            }
            return
        }

        currentNormalizedRect = rect
        showBox(for: rect, animated: animated)
    }

    private func showBox(for normalizedRect: CGRect, animated: Bool) {
        let targetFrame = viewFrame(for: normalizedRect)

        let duration = animated ? 0.18 : 0.0
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
                let badgeWidth: CGFloat = 80
                let badgeHeight: CGFloat = 20
                let badgeX = targetFrame.midX - badgeWidth / 2
                let badgeY = max(targetFrame.minY - badgeHeight - 6, 44)
                self.statusBadge.frame = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
                self.statusBadge.alpha = 1.0
            }
        )

        isBoxVisible = true
    }

    private func hideBox(animated: Bool) {
        guard isBoxVisible else { return }
        isBoxVisible = false
        currentNormalizedRect = nil

        let duration = animated ? 0.3 : 0.0
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            self.boxContainerView.alpha = 0
            self.statusBadge.alpha = 0
        }
    }

    /// 将归一化坐标转换为当前 View 内的实际 Frame
    private func viewFrame(for normalizedRect: CGRect) -> CGRect {
        let viewWidth = bounds.width
        let viewHeight = bounds.height

        return CGRect(
            x: normalizedRect.origin.x * viewWidth,
            y: normalizedRect.origin.y * viewHeight,
            width: normalizedRect.size.width * viewWidth,
            height: normalizedRect.size.height * viewHeight
        )
    }

    /// 绘制具有科技感的四角准星（四个 L 形拐角）
    private func updateCornerPaths(bounds: CGRect) {
        let path = UIBezierPath()
        let cornerLen: CGFloat = min(min(bounds.width, bounds.height) * 0.22, 22)

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
        borderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }
}
