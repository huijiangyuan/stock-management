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
            parent.dismiss()
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
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .photo
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
