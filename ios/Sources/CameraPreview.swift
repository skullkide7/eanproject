import AVFoundation
import SwiftUI

/// Vista de cámara a pantalla completa.
struct CameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> CameraContainerView {
        CameraContainerView(previewLayer: previewLayer)
    }

    func updateUIView(_ uiView: CameraContainerView, context: Context) {
        uiView.fitPreview()
    }
}

final class CameraContainerView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitPreview()
    }

    func fitPreview() {
        previewLayer.frame = bounds
    }
}
