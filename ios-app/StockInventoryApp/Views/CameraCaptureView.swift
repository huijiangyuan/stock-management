import SwiftUI
import AVFoundation

/// 拍照视图（AVFoundation 静态拍照，区别于条码扫码）。拍下后回调 JPEG Data。
struct CameraCaptureView: UIViewControllerRepresentable {
    var onCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> CameraVC {
        let vc = CameraVC()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: CameraVC, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CameraVCDelegate {
        let parent: CameraCaptureView
        init(_ p: CameraCaptureView) { self.parent = p }
        func didCapture(_ data: Data) {
            parent.onCaptured(data)
            // photoOutput 回调可能不在主线程；dismiss 必须在主线程，否则触发
            // UIKit 主线程违规 / 潜在崩溃。将 parent 捕获为局部常量，避免逃逸
            // 闭包里隐式引用 self.parent 的捕获语义报错（编译错误）。
            let capturedParent = parent
            DispatchQueue.main.async { capturedParent.dismiss() }
        }
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "取消", style: .done,
                                                              target: self, action: #selector(close))
        setupCapture()
        addCaptureButton()
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
        session.sessionPreset = .photo
        do {
            session.addInput(input)
            let output = AVCapturePhotoOutput()
            session.addOutput(output)
            self.session = session
            self.output = output
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.insertSublayer(preview, at: 0)
            self.preview = preview
            queue.async { session.startRunning() }
        } catch {
            showErrorAlert(title: "无法开启相机", message: "相机会话配置失败：\(error.localizedDescription)")
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func showCameraDeniedAlert() {
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
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        session?.stopRunning()
        delegate?.didCapture(data)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }
}
