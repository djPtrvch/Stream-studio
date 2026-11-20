import AVFoundation
import SwiftUI
import UIKit

/// Hosts an existing AVCaptureVideoPreviewLayer inside SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(previewLayer: layer)
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(layer)
    }
}

final class PreviewUIView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(_ newLayer: AVCaptureVideoPreviewLayer) {
        guard newLayer !== previewLayer || newLayer.superlayer !== layer else { return }
        previewLayer = newLayer
        layer.addSublayer(newLayer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
