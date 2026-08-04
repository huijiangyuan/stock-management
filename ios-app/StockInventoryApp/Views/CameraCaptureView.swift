import SwiftUI
import AVFoundation

/// 拍照视图（AVFoundation 静态拍照，区别于条码扫码）。拍下后回调 JPEG Data。
struct CameraCaptureView: View {
    var onCaptured: (Data) -> Void

    var body: some View {
        LuminaCameraView(onCaptured: onCaptured)
            .ignoresSafeArea()
    }
}

protocol CameraVCDelegate: AnyObject {
    func didCapture(_ data: Data)
}

final class CameraVC: UIViewController, AVCapturePhotoCaptureDelegate {
    weak var delegate: CameraVCDelegate?
    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var preview: AVCaptureVideoPreviewLayer?
    private let queue = DispatchQueue(label: "camera.capture.queue")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "拍照识别"
        setupNavigationBar()
        setupCapture()
        addCaptureButton()
        addTopCloseButton()
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "取消", style: .done,
            target: self, action: #selector(close)
        )
    }

    @objc private func close() { dismiss(animated: true) }

    private func setupCapture() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.beginCapture() }
            }
        case .denied, .restricted:
            showCameraDeniedAlert()
        @unknown default:
            break
        }
    }

    private func beginCapture() {
        guard session == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            showErrorAlert(title: "无法开启相机", message: "未检测到摄像头设备，请改用「扫码识别」或手动选择原材料。")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            showErrorAlert(title: "无法开启相机", message: "相机输入初始化失败：\(error.localizedDescription)")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            showErrorAlert(title: "无法开启相机", message: "相机会话输入配置失败。")
            return
        }

        let output = AVCapturePhotoOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            session.commitConfiguration()
            showErrorAlert(title: "无法开启相机", message: "相机会话输出配置失败。")
            return
        }

        session.commitConfiguration()

        self.session = session
        self.output = output
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.insertSublayer(preview, at: 0)
        self.preview = preview
        queue.async { session.startRunning() }
    }

    private func showErrorAlert(title: String, message: String) {
        Task { @MainActor in
            AppLogger.shared.log(level: .error, category: .camera, message: title, details: message)
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func showCameraDeniedAlert() {
        Task { @MainActor in
            AppLogger.shared.log(level: .warning, category: .camera, message: "相机权限未授权", details: "用户拒绝或权限未确定")
        }
        let alert = UIAlertController(
            title: "需要相机权限",
            message: "请在「设置 → 库存管理」中开启相机权限，以使用拍照 AI 识别。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }

    private func addTopCloseButton() {
        let btn = UIButton(type: .system)
        btn.setTitle("✕ 取消", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        btn.backgroundColor = UIColor(white: 0, alpha: 0.5)
        btn.layer.cornerRadius = 14
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func addCaptureButton() {
        let btn = UIButton(type: .system)
        btn.setTitle("📷 拍照", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        btn.backgroundColor = UIColor(white: 0, alpha: 0.6)
        btn.layer.cornerRadius = 32
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(shoot), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            btn.widthAnchor.constraint(equalToConstant: 64),
            btn.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    @objc private func shoot() {
        guard let output else { return }
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        queue.async { [weak self] in
            self?.session?.stopRunning()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let smallData = self?.downscaleImageData(data, maxSide: 800) ?? data
            DispatchQueue.main.async {
                self?.delegate?.didCapture(smallData)
            }
        }
    }

    private func downscaleImageData(_ data: Data, maxSide: CGFloat = 800) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.6) ?? data
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }
}
