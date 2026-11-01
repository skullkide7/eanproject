import Foundation
import Vision

/// Detección de EAN compartida por ambas cámaras (iPhone y lentes).
/// Determinista: Vision solo lee el código; el producto siempre viene de Supabase.
enum BarcodeDetector {
    static func detectEAN(in pixelBuffer: CVPixelBuffer) -> String? {
        var found: String?
        let request = VNDetectBarcodesRequest { request, _ in
            guard let results = request.results as? [VNBarcodeObservation] else { return }
            for barcode in results {
                guard [.ean13, .ean8, .upce].contains(barcode.symbology),
                      let ean = barcode.payloadStringValue
                else { continue }
                found = ean
                return
            }
        }
        request.symbologies = [.ean13, .ean8, .upce]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[EANShopper] vision perform falló: \(String(describing: error))")
        }
        return found
    }
}
