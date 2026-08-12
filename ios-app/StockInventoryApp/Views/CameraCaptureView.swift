import AVFoundation
@preconcurrency import NextLevel
import SwiftUI
import UIKit

/// NextLevel 静态拍照入口。完整拍照事务结束后停止相机会话，降低随后模型推理的内存峰值。
struct CameraCaptureView: View {
    let onCaptured: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NextLevelCameraRepresentable(
            onCaptured: { data in
                dismiss()
                onCaptured(data)
            },
            onCancel: {
                dismiss()
            }
        )
        .ignoresSafeArea()
    }
}

private struct NextLevelCameraRepresentable: UIViewControllerRepresentable {
    let onCaptured: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> NextLevelCameraViewController {
        let controller = NextLevelCameraViewController()
        controller.onCaptured = onCaptured
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: NextLevelCameraViewController, context: Context) {}
}

private final class NextLevelCameraViewController: UIViewController {
    enum State: Equatable {
        case idle
        case starting
        case running
        case capturing
        case stopping
        case finished
    }

    var onCaptured: ((Data) -> Void)?
    var onCancel: (() -> Void)?

    private let camera = NextLevel.shared
    private let captureButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var state: State = .idle
    private var pendingPhotoData: Data?
    private var pendingCaptureFailure: String?
    private var shouldCancelAfterStop = false
    private var shouldRestartAfterStop = false
    private var captureWatchdog: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureInterface()
        configureCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        camera.previewLayer.frame = view.layer.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelWatchdogs()
        if state != .finished {
            camera.stop()
            releaseDelegates()
        }
    }

    private func configureCamera() {
        camera.delegate = self
        camera.photoDelegate = self
        camera.captureMode = .photo
        camera.devicePosition = .back
        camera.photoConfiguration.preset = .photo
        camera.photoConfiguration.codec = .jpeg
        camera.photoConfiguration.isHighResolutionEnabled = false
        camera.photoConfiguration.photoQualityPrioritization = .balanced
        camera.previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(camera.previewLayer, at: 0)

        switch NextLevel.authorizationStatus(forMediaType: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            state = .starting
            statusLabel.text = "正在请求相机权限…"
            NextLevel.requestAuthorization(forMediaType: .video) { [weak self] _, status in
                guard let self else { return }
                if status == .authorized {
                    self.startCamera()
                } else {
                    self.presentPermissionDeniedAlert()
                }
            }
        case .notAuthorized:
            presentPermissionDeniedAlert()
        }
    }

    private func startCamera() {
        guard state == .idle || state == .starting else { return }
        state = .starting
        statusLabel.text = "正在启动相机…"
        do {
            try camera.start()
            AppLogger.shared.log(level: .info, category: .camera, message: "NextLevel 相机会话开始启动")
        } catch NextLevelError.started {
            if camera.isRunning {
                nextLevelSessionDidStart(camera)
            } else {
                shouldRestartAfterStop = true
                state = .stopping
                statusLabel.text = "正在重置相机会话…"
                camera.stop { [weak self] in
                    self?.restartAfterStopIfNeeded()
                }
            }
        } catch {
            state = .idle
            presentError(title: "无法启动相机", error: error)
        }
    }

    @objc private func capturePhoto() {
        guard state == .running, camera.canCapturePhoto else {
            AppLogger.shared.log(
                level: .warning,
                category: .camera,
                message: "相机尚未准备好拍照",
                details: "state=\(state), canCapturePhoto=\(camera.canCapturePhoto)"
            )
            return
        }
        state = .capturing
        captureButton.isEnabled = false
        statusLabel.text = "正在拍照…"
        guard camera.capturePhoto() else {
            state = .running
            captureButton.isEnabled = true
            statusLabel.text = "相机输出未就绪，请重试"
            AppLogger.shared.log(
                level: .error,
                category: .camera,
                message: "无法启动静态拍照",
                details: "NextLevel 没有可用的照片输出、视频连接或编码器"
            )
            return
        }
        armCaptureWatchdog()
    }

    @objc private func cancel() {
        guard state != .finished else { return }
        shouldRestartAfterStop = false
        shouldCancelAfterStop = true
        stopSessionAndComplete()
    }

    @objc private func focus(_ recognizer: UITapGestureRecognizer) {
        guard state == .running else { return }
        let point = recognizer.location(in: view)
        let adjustedPoint = camera.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        camera.focusExposeAndAdjustWhiteBalance(atAdjustedPoint: adjustedPoint)
    }

    private func stopSessionAndComplete() {
        guard state != .finished else { return }
        captureWatchdog?.cancel()
        captureWatchdog = nil
        state = .stopping
        statusLabel.text = "正在释放相机资源…"
        armStopWatchdog()
        camera.stop { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        guard state != .finished else { return }
        state = .finished
        cancelWatchdogs()
        releaseDelegates()

        if let data = pendingPhotoData {
            AppLogger.shared.log(
                level: .info,
                category: .camera,
                message: "NextLevel 完成静态拍照并释放相机会话",
                details: "原图数据 \(data.count / 1_024) KB"
            )
            onCaptured?(data)
        } else if pendingCaptureFailure != nil {
            onCancel?()
        } else if shouldCancelAfterStop {
            onCancel?()
        }
    }

    private func restartAfterStopIfNeeded() {
        guard shouldRestartAfterStop, state == .stopping else { return }
        shouldRestartAfterStop = false
        state = .idle
        startCamera()
    }

    private func armCaptureWatchdog() {
        captureWatchdog?.cancel()
        captureWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self, self.state == .capturing else { return }
            self.recordCaptureFailure(
                message: "拍照回调超时",
                details: "10 秒内未收到 AVCapturePhotoCaptureDelegate 完成回调"
            )
            self.stopSessionAndComplete()
        }
    }

    private func armStopWatchdog() {
        stopWatchdog?.cancel()
        stopWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, self.state == .stopping else { return }
            AppLogger.shared.log(
                level: .error,
                category: .camera,
                message: "相机会话停止超时",
                details: "5 秒内未收到 NextLevel 停止完成回调，已强制结束拍照页面"
            )
            self.complete()
        }
    }

    private func recordCaptureFailure(message: String, details: String?) {
        guard pendingCaptureFailure == nil else { return }
        pendingCaptureFailure = details ?? message
        statusLabel.text = "拍照失败，正在释放资源…"
        AppLogger.shared.log(level: .error, category: .camera, message: message, details: details)
    }

    private func cancelWatchdogs() {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        stopWatchdog?.cancel()
        stopWatchdog = nil
    }

    private func releaseDelegates() {
        if camera.delegate === self { camera.delegate = nil }
        if camera.photoDelegate === self { camera.photoDelegate = nil }
    }

    private func configureInterface() {
        let closeButton = UIButton(type: .system)
        closeButton.configuration = .filled()
        closeButton.configuration?.title = "取消"
        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.configuration?.imagePadding = 6
        closeButton.configuration?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.configuration?.baseForegroundColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        captureButton.configuration = .filled()
        captureButton.configuration?.image = UIImage(systemName: "camera.fill")
        captureButton.configuration?.baseBackgroundColor = .white
        captureButton.configuration?.baseForegroundColor = .black
        captureButton.configuration?.cornerStyle = .capsule
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.isEnabled = false
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        statusLabel.text = "正在准备相机…"
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(closeButton)
        view.addSubview(captureButton)
        view.addSubview(statusLabel)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            captureButton.widthAnchor.constraint(equalToConstant: 72),
            captureButton.heightAnchor.constraint(equalToConstant: 72),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -18),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            statusLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func presentError(title: String, error: Error) {
        AppLogger.shared.log(level: .error, category: .camera, message: title, details: error.localizedDescription)
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel) { [weak self] _ in self?.cancel() })
        present(alert, animated: true)
    }

    private func presentPermissionDeniedAlert() {
        state = .idle
        AppLogger.shared.log(level: .warning, category: .camera, message: "相机权限未授权")
        let alert = UIAlertController(
            title: "需要相机权限",
            message: "请在「设置 → 库存管理」中开启相机权限。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.cancel() })
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }
}

extension NextLevelCameraViewController: NextLevelDelegate {
    func nextLevelSessionWillStart(_ nextLevel: NextLevel) {}

    func nextLevelSessionDidStart(_ nextLevel: NextLevel) {
        guard state == .starting else { return }
        state = .running
        captureButton.isEnabled = true
        statusLabel.text = "点击画面可对焦"
        AppLogger.shared.log(level: .info, category: .camera, message: "NextLevel 相机会话已就绪")
    }

    func nextLevelSessionDidStop(_ nextLevel: NextLevel) {
        if shouldRestartAfterStop {
            restartAfterStopIfNeeded()
            return
        }
        if state == .stopping {
            complete()
        }
    }

    func nextLevelSessionWasInterrupted(_ nextLevel: NextLevel) {
        captureButton.isEnabled = false
        statusLabel.text = "相机会话被中断"
        AppLogger.shared.log(level: .warning, category: .camera, message: "NextLevel 相机会话被中断")
    }

    func nextLevelSessionInterruptionEnded(_ nextLevel: NextLevel) {
        statusLabel.text = "相机会话恢复中…"
        AppLogger.shared.log(level: .info, category: .camera, message: "NextLevel 相机会话中断已结束")
    }

    func nextLevel(_ nextLevel: NextLevel, didUpdateVideoConfiguration videoConfiguration: NextLevelVideoConfiguration) {}
    func nextLevel(_ nextLevel: NextLevel, didUpdateAudioConfiguration audioConfiguration: NextLevelAudioConfiguration) {}
    func nextLevelCaptureModeWillChange(_ nextLevel: NextLevel) {}
    func nextLevelCaptureModeDidChange(_ nextLevel: NextLevel) {}
}

extension NextLevelCameraViewController: NextLevelPhotoDelegate {
    func nextLevel(
        _ nextLevel: NextLevel,
        output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        photoConfiguration: NextLevelPhotoConfiguration
    ) {}

    func nextLevel(
        _ nextLevel: NextLevel,
        output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        photoConfiguration: NextLevelPhotoConfiguration
    ) {}

    func nextLevel(
        _ nextLevel: NextLevel,
        output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        photoConfiguration: NextLevelPhotoConfiguration
    ) {}

    func nextLevel(
        _ nextLevel: NextLevel,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        photoDict: [String: Any],
        photoConfiguration: NextLevelPhotoConfiguration
    ) {
        guard state == .capturing else { return }
        guard let data = photoDict[NextLevelPhotoFileDataKey] as? Data else {
            recordCaptureFailure(message: "NextLevel 未返回有效照片数据", details: nil)
            return
        }
        pendingPhotoData = data
        statusLabel.text = "正在完成拍照…"
        AppLogger.shared.log(
            level: .info,
            category: .camera,
            message: "NextLevel 已生成照片数据",
            details: "等待 AVCapturePhotoCaptureDelegate 完成事务，原图数据 \(data.count / 1_024) KB"
        )
    }

    func nextLevel(
        _ nextLevel: NextLevel,
        didFailToCapturePhoto error: any Error,
        photoConfiguration: NextLevelPhotoConfiguration
    ) {
        guard state == .capturing else { return }
        recordCaptureFailure(message: "原生拍照失败", details: error.localizedDescription)
    }

    func nextLevelDidCompletePhotoCapture(_ nextLevel: NextLevel) {
        guard state == .capturing else { return }
        captureWatchdog?.cancel()
        captureWatchdog = nil
        if pendingPhotoData == nil, pendingCaptureFailure == nil {
            recordCaptureFailure(message: "拍照完成但没有生成图片", details: nil)
        }
        AppLogger.shared.log(level: .info, category: .camera, message: "NextLevel 拍照事务已完成，开始释放相机会话")
        stopSessionAndComplete()
    }
}
