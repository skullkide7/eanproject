import AVFoundation
import Foundation
import Speech

/// Entrada por voz para buscar por nombre: micrófono del iPhone a texto
/// con SFSpeechRecognizer en el idioma del dispositivo. El texto se
/// busca igual que si se hubiera escrito; el precio siempre viene de
/// la base de datos, nunca de lo escuchado.
@MainActor
final class VoiceQuery: NSObject, ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    /// Espejo para quien no observa este objeto (pantalla principal):
    /// se llama en cada cambio de escucha o transcripción.
    var onState: ((Bool, String) -> Void)?
    /// Parcial en vivo (para el debounce de 1,5 s del manager).
    var onPartial: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onFinal: ((String) -> Void)?

    /// Pide permiso la primera vez; alterna escuchar/detener.
    /// Al terminar (final o tap) entrega el texto vía onFinal.
    func toggle(onFinal: @escaping (String) -> Void) {
        if listening {
            finish()
            return
        }
        self.onFinal = onFinal
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard status == .authorized else {
                    // Ojo: este permiso (Reconocimiento de voz) es DISTINTO
                    // al del Micrófono. Denegado = dictado mudo para siempre.
                    NSLog("[EANShopper] voz: sin permiso de reconocimiento (\(String(describing: status)))")
                    self?.onFinal = nil
                    return
                }
                self?.start()
            }
        }
    }

    private func start() {
        let locale = Phrasebook.voiceLocale(for: Phrasebook.languageCode())
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            NSLog("[EANShopper] voz: sin reconocedor para \(locale.identifier)")
            onFinal = nil
            return
        }
        guard recognizer.isAvailable else {
            // Sin red (o con restricciones) no hay reconocimiento.
            NSLog("[EANShopper] voz: reconocedor no disponible (\(locale.identifier))")
            onFinal = nil
            return
        }
        // El Speaker deja la sesión en .playback (solo salida): sin
        // pasar a .playAndRecord el formato del input es inválido e
        // installTap revienta con NSException (no atrapable en Swift).
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            NSLog("[EANShopper] voz: audio no activable (\(String(describing: error)))")
            onFinal = nil
            return
        }
        self.recognizer = recognizer
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Segunda red: si igual no hay entrada válida, salir sin crashear.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[EANShopper] voz: formato de entrada inválido (\(format.sampleRate) Hz, \(format.channelCount) ch)")
            restoreAudioSession()
            onFinal = nil
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[EANShopper] voz: engine no arranca (\(String(describing: error)))")
            restoreAudioSession()
            onFinal = nil
            return
        }
        NSLog("[EANShopper] voz: escuchando (\(locale.identifier))")
        audioEngine = engine
        transcript = ""
        listening = true
        emitState()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString,
                   !text.isEmpty
                {
                    self.transcript = text
                    self.emitState()
                    self.onPartial?(text)
                }
                if let error {
                    NSLog("[EANShopper] voz: error reconocimiento (\(String(describing: error)))")
                }
                if result?.isFinal == true || error != nil {
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        listening = false
        restoreAudioSession()
        emitState()
        if !text.isEmpty {
            onFinal?(text)
        }
        onFinal = nil
        transcript = ""
    }

    /// Devuelve la sesión a .playback para que la voz de resultados
    /// suene como antes (el Speaker la había dejado así).
    private func restoreAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    /// Detiene sin entregar nada (cambiar a texto, cerrar hoja).
    /// A diferencia de finish(), no dispara onFinal: no rebusca.
    func stopSilently() {
        onFinal = nil
        onPartial = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        listening = false
        restoreAudioSession()
        emitState()
    }

    private func emitState() {
        onState?(listening, transcript)
    }
}
