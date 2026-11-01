import AVFoundation
import Foundation

/// Cámara del iPhone con salida nativa de metadatos (hardware, sin Vision
/// por frame): la vía más rápida y eficiente para EAN-13/8/UPC-E.
/// (La cámara de los lentes usa frames + Vision en GlassesSession.)
final class PhoneScanner: NSObject, ObservableObject {
    let session = AVCaptureSession()
    var onEAN: ((String) -> Void)?
    private var lastDetection = Date.distantPast
    /// Cadencia de avistamientos (el manager filtra duplicados y detecta
    /// cuándo la cámara deja de mirar el código).
    private let cooldown: TimeInterval = 0.5

    /// Capa de vista previa para mostrar la cámara a pantalla completa.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    override init() {
        super.init()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue(label: "ean.metadata"))
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.metadataObjectTypes = [.ean13, .ean8, .upce]
        #if DEBUG
        addVisionCrossCheck()
        #endif
    }

#if DEBUG
    /// Solo DEBUG: corre Vision sobre frames reales del iPhone y compara
    /// con el hardware (metadatos). Prueba el detector sin lentes.
    private let checkLock = NSLock()
    private var lastMetadataEAN = ""
    private var lastMetadataAt = Date.distantPast
    private var lastCheckAt = Date.distantPast
    /// Se apaga al detener el escáner (modo lentes): así el check no
    /// corre cuando la cámara no es la fuente activa.
    fileprivate var crossCheckEnabled = true

    private func addVisionCrossCheck() {
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ean.visioncheck"))
        guard session.canAddOutput(video) else { return }
        session.addOutput(video)
    }
#endif

    func start() {
        guard !session.isRunning else { return }
        #if DEBUG
        crossCheckEnabled = true
        NSLog("[EANShopper] escáner iPhone iniciado")
        #endif
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        #if DEBUG
        crossCheckEnabled = false
        #endif
        guard session.isRunning else { return }
        session.stopRunning()
        #if DEBUG
        NSLog("[EANShopper] escáner iPhone detenido (running=\(session.isRunning))")
        #endif
    }
}

extension PhoneScanner: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard Date().timeIntervalSince(lastDetection) > cooldown else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let ean = code.stringValue, !ean.isEmpty
            else { continue }
            lastDetection = Date()
            #if DEBUG
            checkLock.lock()
            lastMetadataEAN = ean
            lastMetadataAt = Date()
            checkLock.unlock()
            #endif
            DispatchQueue.main.async { [weak self] in self?.onEAN?(ean) }
            return
        }
    }
}

#if DEBUG
extension PhoneScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        checkLock.lock()
        guard crossCheckEnabled,
              Date().timeIntervalSince(lastCheckAt) > 2,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            checkLock.unlock()
            return
        }
        lastCheckAt = Date()
        let metaEAN = lastMetadataEAN
        let metaAt = lastMetadataAt
        checkLock.unlock()
        let visionEAN = BarcodeDetector.detectEAN(in: pixels) ?? ""
        let metaFresh = Date().timeIntervalSince(metaAt) < 5
        NSLog("[EANShopper] vision-check: vision=\(visionEAN.isEmpty ? "no" : "sí") meta=\(metaFresh ? "sí" : "no") coincide=\(!visionEAN.isEmpty && visionEAN == metaEAN ? "sí" : "no")")
    }
}
#endif
