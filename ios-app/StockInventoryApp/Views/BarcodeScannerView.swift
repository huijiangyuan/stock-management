import SwiftUI
import AVFoundation

/// 条码扫描浮层（AVFoundation），支持 QR / EAN13 / EAN8 / Code128 / Code39。
/// 命中后通过 onDetected 回调并返回。
struct BarcodeScannerView: UIViewControllerRepresentable {
    var onDetected: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, ScannerDelegate {
        let parent: BarcodeScannerView
        init(_ parent: BarcodeScannerView) { self.parent = parent }
        func didFind(code: String) {
            parent.onDetected(code)
            parent.dismiss()
        }
    }
}

protocol ScannerDelegate: AnyObject {
    func didFind(code: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerDelegate?
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "scanner.queue")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupNavigationBar()
        setupCapture()
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "取消", style: .done,
            target: self, action: #selector(close)
        )
    }

    @objc private func close() { dismiss(animated: true) }

    private func setupCapture() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.captureDevice = device
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr, .ean13, .ean8, .code128, .code39]
        self.session = session

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
        addFrameOverlay()
        addOverlayButtons()
        sessionQueue.async { session.startRunning() }
    }

    // MARK: - 浮层按钮（手动输入 / 手电筒）

    private func addOverlayButtons() {
        let manual = makeButton(title: "手动输入", action: #selector(openManualInput))
        let torch = makeButton(title: "手电筒", action: #selector(toggleTorch))
        let stack = UIStackView(arrangedSubviews: [manual, torch])
        stack.axis = .horizontal
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.backgroundColor = UIColor(white: 0, alpha: 0.55)
        b.layer.cornerRadius = 10
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    /// 手动输入：复用与扫码相同的完成路径（delegate.didFind）
    @objc private func openManualInput() {
        let alert = UIAlertController(title: "手动输入条码", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "请输入条码" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let code = alert.textFields?.first?.text, !code.isEmpty else { return }
            self?.delegate?.didFind(code: code)
        })
        present(alert, animated: true)
    }

    /// 手电筒开关（需设备支持）
    @objc private func toggleTorch() {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            device.unlockForConfiguration()
        } catch { }
    }

    private func addFrameOverlay() {
        let size: CGFloat = 240
        let rect = CGRect(x: (view.bounds.width - size) / 2,
                          y: (view.bounds.height - size) / 2,
                          width: size, height: size)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.strokeColor = UIColor.systemBlue.cgColor
        layer.lineWidth = 3
        layer.fillColor = UIColor.clear.cgColor
        view.layer.addSublayer(layer)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue, !code.isEmpty else { return }
        session?.stopRunning()
        delegate?.didFind(code: code)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
}
