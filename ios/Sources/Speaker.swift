import AVFoundation
import Foundation

/// Lee el resultado en voz alta en el idioma del dispositivo.
/// Vive en el main actor: todo su uso ocurre ahí.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var isMuted = false

    override init() {
        super.init()
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    func speak(_ result: ScanResult) {
        guard !isMuted else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let code = Phrasebook.languageCode()
        let text = Phrasebook.phrase(for: result, languageCode: code)
        let utterance = AVSpeechUtterance(string: text)
        // Cadena de reserva: la voz exacta puede no estar instalada
        // (una voz nil habla con la voz por defecto del sistema, que
        // puede ser otro idioma). Nunca quedarse sin voz inglesa.
        utterance.voice = Self.voice(for: code)
        synthesizer.speak(utterance)
    }

    /// Voz más humana disponible: prefiere calidad premium y luego
    /// mejorada (neuronal, descargable gratis) antes que la básica.
    /// Si no hay ninguna instalada, cae igual que antes (inglés).
    /// Las mejoradas se descargan en Ajustes → Accesibilidad →
    /// Contenido hablado → Voces; si no están, se usa la básica.
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let target = Phrasebook.voiceLocale(for: code).identifier
        let prefix = String(target.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matching = voices.filter {
            $0.language == target || $0.language.hasPrefix(prefix)
        }
        let english = voices.filter { $0.language.hasPrefix("en") }
        let picked = matching.first(where: { $0.quality == .premium })
            ?? matching.first(where: { $0.quality == .enhanced })
            ?? matching.first
            ?? english.first(where: { $0.quality == .premium })
            ?? english.first(where: { $0.quality == .enhanced })
            ?? english.first
        #if DEBUG
        if let picked {
            NSLog("[EANShopper] voz habla: \(picked.identifier) (\(picked.language), calidad=\(picked.quality.rawValue))")
        }
        #endif
        return picked
    }

    /// true si la voz elegida es la básica (hay mejora descargable).
    static func isBasicVoice(for code: String) -> Bool {
        voice(for: code)?.quality == .default
    }

    /// Lee la primera coincidencia real completa y para: toda la
    /// tarjeta (nombre + precio + tienda + distancia) sin cortes a la
    /// mitad. Nada la interrumpe salvo una búsqueda o salida explícita
    /// (la retención de 8 s que la cortaba ya no existe).
    func speakNameResults(_ results: [ScanResult]) {
        guard !isMuted, let first = results.first else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let code = Phrasebook.languageCode()
        let utterance = AVSpeechUtterance(string:
            Phrasebook.namePhrase(for: first, languageCode: code))
        utterance.voice = Self.voice(for: code)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
