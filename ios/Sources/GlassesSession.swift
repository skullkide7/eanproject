import CoreMedia
import CoreVideo
import Foundation

#if canImport(MWDATCore)
import MWDATCore
import MWDATCamera
import MWDATDisplay
#if canImport(MWDATInputs)
import MWDATInputs
#endif
#if canImport(MWDATSpeech)
import MWDATSpeech
#endif
#if DEBUG && canImport(MWDATMockDevice)
import MWDATMockDevice
#endif
#if DEBUG && canImport(MWDATMockDeviceTestClient)
import MWDATMockDeviceTestClient
#endif

/// Sesión con los lentes: ciclo de vida, stream de cámara hacia Vision
/// y tarjeta de resultado en el Display.
/// Patrones tomados de los samples CameraAccess/DisplayAccess del DAT SDK.
/// Sin credenciales del Developer Center la sesión simplemente no conecta
/// y la app sigue funcionando con la cámara del iPhone.
final class GlassesSession {
    /// Se activa solo si `Wearables.configure()` tuvo éxito en App.init.
    static var datAvailable = false

    var onFrame: ((String) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Botón físico de acción (o su respaldo en touchpad): arranca la
    /// pregunta por voz sin salir de la pantalla principal.
    var onActionButton: (() -> Void)?
    /// Dictado de los lentes: texto parcial o final. Solo el final
    /// dispara búsqueda; los parciales solo pintan la píldora.
    var onSpeechTranscript: ((String, Bool) -> Void)?
    /// La capability dejó de escuchar sola (inactividad): el manager
    /// decide si rearmar para seguir escuchando en silencio.
    var onSpeechEnded: (() -> Void)?
    private var speechWasStarted = false
    /// Último error de sesión, para mostrarlo en vez de fallar en silencio.
    private(set) var lastError: String?

    private lazy var wearables: WearablesInterface = Wearables.shared
    private lazy var deviceSelector = AutoDeviceSelector(wearables: wearables)
    /// Colector permanente del stream de dispositivos: en iOS el
    /// pipeline solo fluye mientras alguien lo observa (como hace el
    /// sample oficial desde init).
    private var devicesTask: Task<Void, Never>?
    private var devicesStreamTask: Task<Void, Never>?

    /// Prepara el pipeline ANTES de emparejar: el selector debe existir
    /// cuando el mock se anuncia; creado después, pierde el anuncio y
    /// queda en nil aunque devices liste 1.
    func prime() {
        devicesTask?.cancel()
        devicesStreamTask?.cancel()
        // Observar ambos streams en continuo (como el sample desde
        // init): solo encuestar activeDevice sin observarlo lo deja en
        // nil para siempre.
        let selector = deviceSelector
        devicesTask = Task {
            for await _ in selector.activeDeviceStream() {}
        }
        devicesStreamTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await _ in wearables.devicesStream() {}
        }
    }
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var display: Display?
    private let tokenBag = ListenerTokenBag()
    /// Detección en cola dedicada: el hilo que entrega frames nunca se
    /// bloquea; mientras Vision procesa uno, los que llegan se descartan
    /// (no se encolan) mediante el flag de ocupado.
    private let detectQueue = DispatchQueue(label: "ean.glasses.detect")
    private let detectLock = NSLock()
    private var detecting = false

    var isConnected: Bool {
        deviceSession?.state == .started
    }

    func start() async {
        guard Self.datAvailable else {
            lastError = L10n.t("noCreds")
            Task { @MainActor [weak self] in
                self?.onConnectionChange?(false)
            }
            return
        }
        guard deviceSession == nil else { return }
        // Como el sample oficial: registro en Meta AI antes de crear
        // sesión. Sin esto, el dispositivo nunca es "elegible".
        guard await ensureRegistered(timeout: 60) else {
            if lastError == nil {
                lastError = L10n.t("regPending")
            }
            Task { @MainActor [weak self] in
                self?.onConnectionChange?(false)
            }
            return
        }
        // El selector se puebla de forma asíncrona: sin esta espera
        // createSession falla con noEligibleDevice aunque el mock ya
        // esté emparejado.
        prime()
        _ = await waitForDevice(timeout: 6)
        do {
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            try launch(session)
            return
        } catch {
            logVisibleDevice(prefix: "auto")
            NSLog("[EANShopper] createSession auto falló: \(String(describing: error))")
        }
        // Fallback: selector específico al primer dispositivo visible.
        guard let id = wearables.devices.first else {
            lastError = L10n.t("noGlasses")
            Task { @MainActor [weak self] in
                self?.onConnectionChange?(false)
            }
            return
        }
        do {
            let session = try wearables.createSession(
                deviceSelector: SpecificDeviceSelector(device: id))
            try launch(session)
        } catch {
            deviceSession = nil
            lastError = String(describing: error)
            Task { @MainActor [weak self] in
                self?.onConnectionChange?(false)
            }
        }
    }

    /// Detalle del dispositivo visible (nombre + compatibilidad) para
    /// diagnosticar por qué el selector automático lo filtra.
    private func logVisibleDevice(prefix: String) {
        let count = wearables.devices.count
        guard let id = wearables.devices
            .first,
              let device = wearables.deviceForIdentifier(id)
        else {
            NSLog("[EANShopper] \(prefix): registration=\(wearables.registrationState) devices=\(count)")
            return
        }
        NSLog("[EANShopper] \(prefix): registration=\(wearables.registrationState) devices=\(count) name=\(device.nameOrId()) type=\(device.deviceType()) link=\(device.linkState) compat=\(String(describing: device.compatibility()))")
    }

    /// Suscribe estado y arranca la sesión creada.
    private func launch(_ session: DeviceSession) throws {
        deviceSession = session
        session.statePublisher.listen { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onConnectionChange?(self?.isConnected ?? false)
            }
        }.store(in: tokenBag)
        session.errorPublisher.listen { error in
            NSLog("[EANShopper] session error: \(String(describing: error))")
        }.store(in: tokenBag)
        try session.start()
    }

    /// Registro en Meta AI (puede abrir la app de Meta AI; al volver,
    /// el callback eanshopper:// completa el flujo vía handleUrl).
    private func ensureRegistered(timeout: TimeInterval) async -> Bool {
        if wearables.registrationState == .registered { return true }
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = String(describing: error)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while wearables.registrationState != .registered, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return wearables.registrationState == .registered
    }

    /// Espera a que el selector vea un dispositivo elegible (hasta
    /// `timeout` segundos). El selector se puebla observando el stream
    /// de forma asíncrona: sin esta espera, createSession corre con
    /// activeDevice en nil y lanza noEligibleDevice.
    private func waitForDevice(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while deviceSelector.activeDevice == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return deviceSelector.activeDevice != nil
    }

    func stop() {
        devicesTask?.cancel()
        devicesTask = nil
        devicesStreamTask?.cancel()
        devicesStreamTask = nil
        feedRefreshed = false
        loggedFirstFrame = false
        loggedFrameInfo = false
        loggedRawFrame = false
        loggedUnextractable = false
        camera?.stop()
        camera = nil
        display = nil
        setDisplayReady(false)
        #if canImport(MWDATInputs)
        teardownInputs()
        #endif
        #if canImport(MWDATSpeech)
        teardownSpeech()
        #endif
        deviceSession?.stop()
        deviceSession = nil
        Task { @MainActor [weak self] in
            self?.onConnectionChange?(false)
        }
    }

    /// Cámara de los lentes: frames → mismo detector Vision del iPhone.
    func startCameraStream() {
        guard let session = deviceSession,
              session.state == .started, camera == nil
        else {
            NSLog("[EANShopper] stream no iniciado: state=\(String(describing: deviceSession?.state))")
            return
        }
        // Codec raw: frames BGRA directos a Vision. Con hvc1 habría
        // que decodificar HEVC (los sample buffers llegan comprimidos
        // y sin pixel buffer).
        let config = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )
        do {
            guard let newCamera = try session.addCamera(config: config) else {
                NSLog("[EANShopper] addCamera devolvió nil")
                return
            }
            NSLog("[EANShopper] cámara de lentes creada, iniciando stream")
            camera = newCamera
            newCamera.stream.statePublisher.listen { [weak self] state in
                NSLog("[EANShopper] stream state=\(String(describing: state))")
                if state == .streaming, self?.feedRefreshed == false {
                    self?.feedRefreshed = true
                    MockGlassesHelper.refreshPhoneFeed()
                }
            }.store(in: tokenBag)
            newCamera.stream.errorPublisher.listen { error in
                NSLog("[EANShopper] stream error: \(String(describing: error))")
            }.store(in: tokenBag)
            newCamera.stream.videoFramePublisher.listen { [weak self] frame in
                guard let self else { return }
                self.detectLock.lock()
                if !self.loggedRawFrame {
                    self.loggedRawFrame = true
                    NSLog("[EANShopper] frame crudo del stream recibido")
                }
                self.detectLock.unlock()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
                    self.detectLock.lock()
                    if !self.loggedUnextractable {
                        self.loggedUnextractable = true
                        NSLog("[EANShopper] frame sin pixel buffer (comprimido?)")
                    }
                    self.detectLock.unlock()
                    return
                }
                self.handleVideoFrame(pixelBuffer)
            }.store(in: tokenBag)
            newCamera.stream.start()
        } catch {
            camera = nil
            lastError = String(describing: error)
            NSLog("[EANShopper] stream falló: \(String(describing: error))")
        }
    }

    private var loggedFirstFrame = false
    private var loggedFrameInfo = false
    private var feedRefreshed = false
    private var loggedRawFrame = false
    private var loggedUnextractable = false

    private func handleVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        detectLock.lock()
        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog("[EANShopper] primer frame de lentes recibido")
        }
        guard !detecting else {
            detectLock.unlock()
            return
        }
        detecting = true
        detectLock.unlock()
        let callback = onFrame
        // Fuera del hilo de entrega: el siguiente frame no espera a Vision.
        detectQueue.async { [weak self] in
            let ean = BarcodeDetector.detectEAN(in: pixelBuffer)
            self?.detectLock.lock()
            let first = self?.loggedFrameInfo == false
            self?.loggedFrameInfo = true
            self?.detecting = false
            self?.detectLock.unlock()
            if first {
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                // Luminosidad media del plano 0: ~0 = frame negro (el
                // feed del mock no entrega imagen real).
                var mean = -1
                if CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess {
                    if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
                        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                        var sum = 0, n = 0, y = 0
                        while y < h {
                            var x = 0
                            while x < w {
                                sum += Int(base.load(fromByteOffset: y * bpr + x, as: UInt8.self))
                                n += 1
                                x += 16
                            }
                            y += 16
                        }
                        if n > 0 { mean = sum / n }
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                }
                NSLog("[EANShopper] frame lentes: \(w)x\(h) fmt=\(String(format: "%08X", fmt)) luma=\(mean) ean=\(ean == nil ? "no" : "sí")")
            }
            // Al main solo viaja el EAN (String, Sendable), nunca el buffer.
            if let ean {
                NSLog("[EANShopper] lentes: EAN detectado, buscando precio")
                Task { @MainActor in callback?(ean) }
            }
        }
    }

    #if canImport(MWDATInputs)
    /// Decide si un evento de Inputs arranca la pregunta por voz.
    /// Solo el botón físico de acción y el toque de confirmación en el
    /// touchpad; la captura (foto/video) jamás dispara búsqueda.
    /// Pura para poder testearla sin hardware.
    func glassesInputTriggersVoiceSearch(_ event: InputEvent) -> Bool {
        switch event {
        case .nav:
            return false
        case .select(let source, _):
            // Respaldo: el botón de acción no está validado en todo el
            // hardware (docs oficiales), el touchpad sí es su superficie.
            return source == .captouch
        case .back:
            return false
        case .button(let type, let source, _):
            return type == .action && source == .actionButton
        case .capture:
            return false
        case .drag:
            return false
        @unknown default:
            return false
        }
    }

    /// Inputs tras sesión iniciada: sin sesión en `.started`, addInputs
    /// devuelve nil. Pide solo las superficies usadas (acción + touchpad)
    /// y no consume el back del sistema. Beta: con Developer Mode activo,
    /// si no llegan eventos el problema está en este código.
    func startInputs() {
        guard let session = deviceSession,
              session.state == .started, inputs == nil
        else { return }
        let config = InputsConfiguration(
            sources: [.actionButton, .captouch], consumeBack: false)
        do {
            guard let capability = try session.addInputs(configuration: config) else {
                NSLog("[EANShopper] addInputs devolvió nil (sesión no iniciada?)")
                return
            }
            inputs = capability
            capability.statePublisher.listen { state in
                NSLog("[EANShopper] inputs state=\(String(describing: state))")
            }.store(in: tokenBag)
            capability.errorPublisher.listen { error in
                NSLog("[EANShopper] inputs error: \(String(describing: error))")
            }.store(in: tokenBag)
            inputsTask?.cancel()
            inputsTask = Task { [weak self] in
                guard let events = self?.inputs?.events else { return }
                for await event in events {
                    self?.handleInputEvent(event)
                    if Task.isCancelled { break }
                }
            }
        } catch {
            inputs = nil
            NSLog("[EANShopper] addInputs falló: \(String(describing: error))")
        }
    }

    private var inputsTask: Task<Void, Never>?
    private var inputs: Inputs?
    /// Anti-rebote: una pulsación = un evento, pero dos gestos juntos
    /// (botón + touchpad) no deben lanzar dos búsquedas.
    private var lastVoiceTriggerAt = Date.distantPast

    private func handleInputEvent(_ event: InputEvent) {
        switch event {
        case .nav(let direction, let source, _):
            NSLog("[EANShopper] inputs nav \(String(describing: direction)) src=\(String(describing: source))")
        case .select(let source, _):
            NSLog("[EANShopper] inputs select src=\(String(describing: source))")
            if glassesInputTriggersVoiceSearch(event) { fireActionButton() }
        case .back(let source, _):
            NSLog("[EANShopper] inputs back src=\(String(describing: source))")
        case .button(let type, let source, _):
            NSLog("[EANShopper] inputs button \(String(describing: type)) src=\(String(describing: source))")
            if glassesInputTriggersVoiceSearch(event) { fireActionButton() }
        case .capture(let press, let source, _):
            // Captura = foto/video por defecto: se registra y se ignora.
            NSLog("[EANShopper] inputs capture \(String(describing: press)) src=\(String(describing: source)) (ignorado)")
        case .drag(let action, _, _, _, _, let source, _):
            NSLog("[EANShopper] inputs drag \(String(describing: action)) src=\(String(describing: source))")
        @unknown default:
            break
        }
    }

    private func fireActionButton() {
        guard Date().timeIntervalSince(lastVoiceTriggerAt) >= 1.0 else { return }
        lastVoiceTriggerAt = Date()
        NSLog("[EANShopper] botón acción lentes → pregunta por voz")
        let callback = onActionButton
        Task { @MainActor in callback?() }
    }

    /// Limpieza de Inputs al desconectar.
    private func teardownInputs() {
        inputsTask?.cancel()
        inputsTask = nil
        inputs = nil
        if let session = deviceSession {
            try? session.removeInputs()
        }
    }
    #endif
    #if !canImport(MWDATInputs)
    func startInputs() {}
    #endif

    #if canImport(MWDATSpeech)
    /// Dictado con el micrófono de los lentes (ASR de Meta, en el idioma
    /// de los lentes). Devuelve false si no pudo arrancar (sesión no
    /// iniciada o permiso MICROPHONE denegado): el llamador cae al
    /// micrófono del iPhone. Los parciales reemplazan al anterior; solo
    /// el final dispara búsqueda.
    func startListening() async -> Bool {
        guard let session = deviceSession, session.state == .started else {
            return false
        }
        do {
            let status = try await wearables.checkPermissionStatus(.microphone)
            if status != .granted {
                NSLog("[EANShopper] dictado lentes: pidiendo permiso MICROPHONE")
                let asked = try await wearables.requestPermission(.microphone)
                guard asked == .granted else {
                    NSLog("[EANShopper] dictado lentes: MICROPHONE denegado")
                    return false
                }
            }
        } catch {
            NSLog("[EANShopper] dictado lentes: permiso falló (\(String(describing: error)))")
            return false
        }
        do {
            if speech == nil {
                guard let capability = try session.addSpeech() else {
                    NSLog("[EANShopper] addSpeech devolvió nil")
                    return false
                }
                speech = capability
                capability.statePublisher.listen { [weak self] state in
                    NSLog("[EANShopper] speech state=\(String(describing: state))")
                    if state == .started {
                        self?.speechWasStarted = true
                    }
                    if state == .stopped,
                       self?.speechWasStarted == true
                    {
                        self?.speechWasStarted = false
                        let callback = self?.onSpeechEnded
                        Task { @MainActor in callback?() }
                    }
                }.store(in: tokenBag)
                capability.errorPublisher.listen { error in
                    NSLog("[EANShopper] speech error: \(String(describing: error))")
                }.store(in: tokenBag)
                capability.transcriptionPublisher.listen { [weak self] result in
                    let callback = self?.onSpeechTranscript
                    let text = result.text, isFinal = result.isFinal
                    Task { @MainActor in callback?(text, isFinal) }
                }.store(in: tokenBag)
            }
            speech?.start()
            NSLog("[EANShopper] dictado lentes: escuchando (locale=\(speech?.locale ?? "?"))")
            return true
        } catch {
            speech = nil
            NSLog("[EANShopper] addSpeech falló: \(String(describing: error))")
            return false
        }
    }

    private var speech: Speech?

    /// Deja de escuchar (segunda pulsación): no borra la capability.
    func stopListening() {
        speech?.stop()
    }

    private func teardownSpeech() {
        speech?.stop()
        speech = nil
        if let session = deviceSession {
            try? session.removeSpeech()
        }
    }
    #endif
    #if !canImport(MWDATSpeech)
    func startListening() async -> Bool { false }
    func stopListening() {}
    #endif

    /// Tarjeta de resultado en el Display de los lentes.
    func showResult(_ result: ScanResult) async {
        guard let session = deviceSession, session.state == .started else { return }
        do {
            if display == nil {
                // Como el sample DisplayAccess: agregar, observar estado
                // y arrancar; enviar solo cuando esté .started.
                let capability = try session.addDisplay()
                display = capability
                setDisplayReady(false)
                capability.statePublisher.listen { [weak self] state in
                    self?.setDisplayReady(state == .started)
                }.store(in: tokenBag)
                capability.start()
            }
            guard display != nil else { return }
            guard await waitDisplayReady(timeout: 10) else {
                NSLog("[EANShopper] display no listo, tarjeta no enviada")
                return
            }
            guard let display else { return }
            try await display.send(ResultCardView.card(for: result))
            NSLog("[EANShopper] tarjeta enviada al display")
        } catch {
            display = nil
            NSLog("[EANShopper] display falló: \(String(describing: error))")
        }
    }

    private let displayLock = NSLock()
    private var displayReady = false

    private func setDisplayReady(_ value: Bool) {
        displayLock.lock()
        displayReady = value
        displayLock.unlock()
    }

    private func isDisplayReady() -> Bool {
        displayLock.lock()
        let value = displayReady
        displayLock.unlock()
        return value
    }

    /// Espera a que el display esté listo (hasta `timeout` segundos).
    private func waitDisplayReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDisplayReady(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isDisplayReady()
    }

#if DEBUG && canImport(MWDATMockDevice)
    /// Prueba la ruta de Display con un mock CON pantalla (el mock de
    /// cámara .rayBanMeta no tiene display y addDisplay fallaría).
    /// Devuelve el resultado en texto para mostrar en el cartel.
    func testDisplay(result: ScanResult) async -> String {
        guard Self.datAvailable else { return L10n.t("noCredsShort") }
        guard await ensureRegistered(timeout: 60) else {
            return L10n.t("regPendingShort")
        }
        do {
            MockDeviceKit.shared.enable()
            let mock = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            mock.powerOn()
            mock.unfold()
            mock.don()
        } catch {
            return "\(L10n.t("mockPairFail")) \(String(describing: error))"
        }
        let selector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
        let observer = Task {
            for await _ in selector.activeDeviceStream() {}
        }
        let deadline = Date().addingTimeInterval(8)
        while selector.activeDevice == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        observer.cancel()
        guard selector.activeDevice != nil else { return L10n.t("mockNotEligible") }
        do {
            let session = try wearables.createSession(deviceSelector: selector)
            try session.start()
            let deadline2 = Date().addingTimeInterval(8)
            while session.state != .started, Date() < deadline2 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard session.state == .started else {
                session.stop()
                return L10n.t("sessionNotStarted")
            }
            let capability = try session.addDisplay()
            setDisplayReady(false)
            capability.statePublisher.listen { [weak self] state in
                self?.setDisplayReady(state == .started)
            }.store(in: tokenBag)
            capability.start()
            guard await waitDisplayReady(timeout: 10) else {
                session.stop()
                return L10n.t("displayNotReady")
            }
            try await capability.send(ResultCardView.card(for: result))
            session.stop()
            return L10n.t("displaySent")
        } catch {
            return "\(L10n.t("displayFailed")) \(String(describing: error))"
        }
    }
#endif
}

#else

/// Sin DAT SDK (o sin credenciales): sesión nula, la app usa el iPhone.
final class GlassesSession {
    var onFrame: ((String) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onActionButton: (() -> Void)?
    var onSpeechTranscript: ((String, Bool) -> Void)?
    var onSpeechEnded: (() -> Void)?
    var lastError: String? { nil }
    var isConnected: Bool { false }
    func start() async {}
    func testDisplay(result: ScanResult) async -> String { "Prueba no disponible sin SDK." }
    func stop() {}
    func startCameraStream() {}
    func startInputs() {}
    func startListening() async -> Bool { false }
    func stopListening() {}
    func showResult(_ result: ScanResult) async {}
}

#endif

/// Acumulador del dictado: los parciales reemplazan (docs oficiales),
/// solo el final se entrega para buscar. Puro y testeable.
struct SpeechAccumulator {
    private(set) var text = ""
    /// Devuelve el texto a buscar cuando llega el final, nil si no.
    mutating func feed(text: String, isFinal: Bool) -> String? {
        self.text = text
        return isFinal ? text : nil
    }
}
