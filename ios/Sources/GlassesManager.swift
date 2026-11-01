import CoreLocation
import Foundation

#if canImport(MWDATCore)
import MWDATCore
#endif

/// Clase central: fuente de cámara (iPhone hoy, lentes en Fase 4),
/// fix GPS fresco por escaneo, lookup, tarjeta y voz.
@MainActor
final class GlassesManager: NSObject, ObservableObject {
    enum CameraSource: String {
        case phone = "iPhone"
        case glasses = "Lentes"
    }

    enum ScanState: Equatable {
        case idle
        case scanning
        case noLocation
        case notFoundNearby
        case error(String)

        static func == (lhs: ScanState, rhs: ScanState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning),
                 (.noLocation, .noLocation),
                 (.notFoundNearby, .notFoundNearby): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var cameraSource: CameraSource = .phone
    @Published var scanState: ScanState = .idle
    @Published var lastResult: ScanResult?
    @Published var lastKnownPlace: String = L10n.t("unknownPlace")
    @Published var locationAccuracyM: Double?
    @Published var glassesConnected = false
    @Published var lastEAN: String?
    @Published var glassesError: String?
    @Published var isLookingUp = false
    /// Coincidencias reales de buscar por nombre, ordenadas por cercanía.
    @Published var nameResults: [ScanResult] = []
    /// Retención en pantalla de resultados por nombre (8 s, como manual).
    private var nameResultsUntil: Date?
    /// Tarjeta guía para descargar la voz mejorada (una sola vez).
    @Published var showVoiceUpgrade = false
    private let voiceUpgradeSeenKey = "voiceUpgradePromptSeen"
    @Published var isMuted = false {
        didSet { speaker.isMuted = isMuted }
    }
    /// Último EAN a la vista y cuándo se vio por última vez.
    private var lastSeenEAN: String?
    private var lastSeenAt = Date.distantPast
    /// EAN ya procesado (lookup + voz). Igual EAN a la vista: no repetir.
    private var lastProcessedEAN: String?
    private var lastSpokenEAN: String?
    /// GPS convergiendo en segundo plano mientras la cámara corre.
    private var trackingLocation: CLLocation?
    private var didLogStartup = false
    /// Tag único por build para saber qué código corre el iPhone.
    /// Subirlo en cada cambio que deba verificarse en dispositivo.
    private static let buildTag = "b93"

    let scanner = PhoneScanner()
    let speaker = Speaker()
    let glassesSession = GlassesSession()
    /// Pregunta por voz: una sola instancia para la hoja del teléfono
    /// y el botón físico de los lentes (mismo flujo en ambos).
    let voiceSearch = VoiceQuery()
    /// Espejos para la UI: VoiceQuery ya publica, pero la pantalla
    /// principal solo observa al manager.
    @Published var voiceListening = false
    @Published var voiceTranscript = ""
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var pendingCollector: LocationCollector?
    private var store: PriceStore = SampleStore()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        if BackendConfig.isConfigured {
            store = LiveSupabaseStore()
        }
        scanner.onEAN = { [weak self] ean in
            self?.noteEANSeen(ean)
        }
        voiceSearch.onState = { [weak self] listening, transcript in
            self?.voiceListening = listening
            self?.voiceTranscript = transcript
        }
        glassesSession.onActionButton = { [weak self] in
            Task { @MainActor [weak self] in
                self?.startVoiceSearch()
            }
        }
        glassesSession.onSpeechTranscript = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                self?.voiceHeard(text: text, isFinal: isFinal, from: .glasses)
            }
        }
        glassesSession.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.glassesSpeechEnded()
            }
        }
        glassesSession.onConnectionChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.glassesConnected = connected
                self?.cameraSource = connected ? .glasses : .phone
                self?.glassesError = connected
                    ? nil : self?.glassesSession.lastError
                if connected {
                    self?.scanner.stop()
                    self?.glassesSession.startCameraStream()
                    self?.glassesSession.startInputs()
                    // Si la hoja de voz está abierta, cambia a lentes.
                    self?.stopVoicePaths()
                    Task { await self?.startVoicePathIfNeeded() }
                } else {
                    // Al desconectar, la cámara del iPhone retoma: sin
                    // esto la pantalla queda congelada hasta reabrir.
                    // Si la hoja de voz está abierta, cambia a teléfono.
                    self?.stopVoicePaths()
                    self?.scanner.start()
                    Task { await self?.startVoicePathIfNeeded() }
                }
            }
        }
        glassesSession.onFrame = { [weak self] ean in
            self?.noteEANSeen(ean)
        }
    }

    /// Configura el SDK en segundo plano, fuera del arranque crítico.
    /// configure() es una sola vez por proceso: repetirlo lanza
    /// WearablesError(rawValue: 1) ("ya configurado").
    func configureGlasses() async {
        #if canImport(MWDATCore)
        if GlassesSession.datAvailable { return }
        if let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] {
            let keys = mwdat.keys.sorted().joined(separator: ",")
            let appIDLen = (mwdat["MetaAppID"] as? String)?.count ?? -1
            let tokenLen = (mwdat["ClientToken"] as? String)?.count ?? -1
            NSLog("[EANShopper] MWDAT en bundle: keys=[\(keys)] MetaAppID.len=\(appIDLen) ClientToken.len=\(tokenLen)")
        } else {
            NSLog("[EANShopper] MWDAT AUSENTE en el bundle: el Info.plist instalado no trae el bloque")
        }
        do {
            try Wearables.configure()
            GlassesSession.datAvailable = true
            // Selector vivo antes de cualquier emparejamiento.
            glassesSession.prime()
        } catch {
            if error.rawValue == 1 {
                // Ya estaba configurado por una llamada anterior: éxito.
                GlassesSession.datAvailable = true
            } else {
                NSLog("[EANShopper] DAT SDK no configurado (sin credenciales): \(error)")
            }
        }
        #endif
    }

    /// Precalienta la conexión con Supabase (llamar al abrir la app).
    func prewarmBackend() {
        Task.detached {
            await LiveSupabaseStore.prewarm()
        }
    }

    /// Evita conexiones superpuestas (doble tap): dos sesiones en
    /// carrera emparejan dos mocks y la primera falla.
    private var connecting = false

    /// Conecta con los lentes (reales o simulados) e inicia sesión.
    /// El SDK se configura recién aquí, fuera del arranque de la app.
    func connectGlasses() {
        guard !connecting else { return }
        connecting = true
        Task {
            await configureGlasses()
            await glassesSession.start()
            connecting = false
        }
    }

    /// Indica si la conexión actual es simulada (mock DEBUG).
    @Published var simActive = false

    func disconnectGlasses() {
        if simActive {
            simActive = false
            MockGlassesHelper.disable()
        }
        // La UI y la cámara del iPhone retoman DE INMEDIATO: el teardown
        // de la sesión corre después, y si se cuelga la pantalla no
        // queda pegada en lentes (el false tardío es idempotente).
        glassesConnected = false
        cameraSource = .phone
        glassesError = nil
        scanner.start()
        glassesSession.stop()
    }

    /// Solo DEBUG: configura primero y empareja después (al revés, el
    /// configure() puede limpiar el mock recién emparejado).
    func simulateGlasses() {
        guard !connecting else { return }
        connecting = true
        // Suelta la cámara del iPhone antes de que el mock la tome como
        // feed; dos sesiones activas sobre la misma cámara se pelean.
        scanner.stop()
        #if DEBUG
        simActive = true
        MockGlassesHelper.liveFeedWanted = true
        #endif
        Task {
            await configureGlasses()
            #if DEBUG
            MockGlassesHelper.enableAndPair()
            #endif
            await glassesSession.start()
            connecting = false
        }
    }

    /// Solo DEBUG: inyecta un botón de acción en el mock emparejado
    /// para verificar el camino evento → pregunta por voz sin hardware.
    func testActionButton() {
        #if DEBUG
        MockGlassesHelper.injectActionButton()
        #endif
    }

    /// Solo DEBUG: abre el buscador en voz e inyecta un texto simulado
    /// para verificar lentes → texto → búsqueda sin hardware.
    func testSpeechTranscription() {
        #if DEBUG
        nameSearchVoiceMode = true
        openNameSearch = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            await startVoicePathIfNeeded()
            MockGlassesHelper.injectTranscription("¿cuánto cuestan los tallarines?")
        }
        #endif
    }

    /// Solo DEBUG: envía la última tarjeta al display de un mock con
    /// pantalla. Verifica la ruta Display sin hardware real.
    func testDisplay() {
        #if DEBUG
        guard let result = lastResult else {
            glassesError = L10n.t("scanFirst")
            return
        }
        Task {
            await configureGlasses()
            let outcome = await glassesSession.testDisplay(result: result)
            glassesError = outcome
            NSLog("[EANShopper] prueba display: \(outcome)")
        }
        #endif
    }

    /// Entrada manual de EAN (menú) y pruebas sin cámara.
    /// Pasa por noteEANSeen como la cámara: si no, el guard
    /// anti-tardíos de handleEAN descarta el resultado en silencio.
    func debugLookup(ean: String) {
        let clean = ean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Re-lookup y voz aunque sea el mismo EAN: el ingreso manual
        // es intención explícita, no un re-avistamiento.
        lastProcessedEAN = ""
        lastSpokenEAN = ""
        noteEANSeen(clean)
        manualHoldUntil = Date().addingTimeInterval(8)
    }

    /// Hoja del buscador abierta y en qué modo (voz por defecto).
    @Published var openNameSearch = false
    @Published var nameSearchVoiceMode = true
    /// Ruta de escucha activa: lentes, teléfono o ninguna.
    private enum VoicePath { case none, glasses, phone }
    private var voicePath: VoicePath = .none
    private var speechAccumulator = SpeechAccumulator()
    /// Anti-bucle: solo se rearma la escucha si la sesión anterior
    /// vivió más de 2 s (si muere al instante, algo está mal y no se
    /// gira en caliente).
    private var voicePathStartedAt = Date.distantPast
    /// Confirmación de fin de habla: se envía 1,5 s después de que la
    /// persona deja de hablar, para que una pausa no mande el audio.
    /// Un parcial nuevo en la ventana cancela el envío (sigue hablando).
    private var voiceConfirmTask: Task<Void, Never>?
    private var voiceGeneration = 0

    /// Botón físico de los lentes: abre el buscador desde la pantalla
    /// principal. La escucha arranca sola adentro (onNameSearchAppear),
    /// sin segundo paso.
    func startVoiceSearch() {
        nameSearchVoiceMode = true
        openNameSearch = true
        Task { await startVoicePathIfNeeded() }
    }

    /// La hoja apareció en modo voz: escucha sola (lentes si están
    /// conectados, teléfono si no), sin apretar nada.
    func onNameSearchAppear() {
        nameSearchVoiceMode = true
        Task { await startVoicePathIfNeeded() }
    }

    /// La hoja se cerró: se detiene todo y, si quedó texto sin enviar,
    /// se busca (equivale a terminar el dictado al salir).
    func closeVoiceScreen() {
        let leftover = speechAccumulator.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stopVoicePaths()
        speechAccumulator = SpeechAccumulator()
        voiceTranscript = ""
        guard !leftover.isEmpty else { return }
        searchByName(leftover)
    }

    func switchToTextMode() {
        nameSearchVoiceMode = false
        stopVoicePaths()
        speechAccumulator = SpeechAccumulator()
        voiceTranscript = ""
    }

    func switchToVoiceMode() {
        nameSearchVoiceMode = true
        Task { await startVoicePathIfNeeded() }
    }

    func startVoicePathIfNeeded() async {
        guard openNameSearch, nameSearchVoiceMode, voicePath == .none else { return }
        speechAccumulator = SpeechAccumulator()
        voiceTranscript = ""
        voicePathStartedAt = Date()
        if glassesConnected {
            voicePath = .glasses
            let ok = await glassesSession.startListening()
            guard ok else {
                // Sin permiso o sin capability: respaldo al teléfono.
                NSLog("[EANShopper] dictado lentes no arrancó, respaldo a iPhone")
                voicePath = .none
                startPhoneVoice()
                return
            }
            voiceListening = true
        } else {
            startPhoneVoice()
        }
    }

    private func startPhoneVoice() {
        voicePath = .phone
        voicePathStartedAt = Date()
        voiceListening = true
        voiceSearch.onPartial = { [weak self] text in
            self?.voiceHeard(text: text, isFinal: false, from: .phone)
        }
        voiceSearch.toggle { [weak self] text in
            self?.phoneVoiceEnded(text: text)
        }
    }

    /// Fin de una sesión del teléfono: se programa el envío con
    /// confirmación y se rearma para que, si la persona retomó en la
    /// ventana, el parcial nuevo cancele el envío.
    private func phoneVoiceEnded(text: String) {
        voiceHeard(text: text, isFinal: true, from: .phone)
        guard openNameSearch, nameSearchVoiceMode, voicePath == .phone else { return }
        guard Date().timeIntervalSince(voicePathStartedAt) > 2 else {
            NSLog("[EANShopper] voz teléfono murió al instante, no se rearma")
            voicePath = .none
            voiceListening = false
            return
        }
        startPhoneVoice()
    }

    /// La capability se detuvo sola: se rearma para seguir escuchando
    /// en silencio (con la misma red anti-bucle).
    func glassesSpeechEnded() {
        guard voicePath == .glasses, openNameSearch, nameSearchVoiceMode else { return }
        guard Date().timeIntervalSince(voicePathStartedAt) > 2 else {
            NSLog("[EANShopper] dictado lentes murió al instante, no se rearma")
            voicePath = .none
            voiceListening = false
            return
        }
        Task { await startVoicePathIfNeeded() }
    }

    /// Cada texto (parcial o final) de cualquier ruta. El envío lo
    /// decide nuestro silencio de 1,5 s, no el "final" del reconocedor
    /// (que a veces no llega nunca): cada texto nuevo reinicia la
    /// ventana; 1,5 s sin texto nuevo = la persona dejó de hablar.
    private func voiceHeard(text: String, isFinal: Bool, from path: VoicePath) {
        guard voicePath == path, openNameSearch, nameSearchVoiceMode else { return }
        voiceGeneration += 1
        voiceTranscript = text
        _ = speechAccumulator.feed(text: text, isFinal: isFinal)
        voiceConfirmTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleVoiceConfirm(generation: voiceGeneration)
    }

    private func scheduleVoiceConfirm(generation: Int) {
        voiceConfirmTask?.cancel()
        voiceConfirmTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { [weak self] in
                guard let self,
                      generation == self.voiceGeneration,
                      self.openNameSearch, self.nameSearchVoiceMode
                else { return }
                self.dispatchVoiceSearch()
            }
        }
    }

    /// Ventana cumplida sin habla nueva: se envía, se cierra la hoja y
    /// el resultado sigue el flujo normal (tarjeta + voz).
    private func dispatchVoiceSearch() {
        let text = speechAccumulator.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stopVoicePaths()
        speechAccumulator = SpeechAccumulator()
        voiceTranscript = ""
        openNameSearch = false
        guard !text.isEmpty else { return }
        searchByName(text)
    }

    private func stopVoicePaths() {
        voiceConfirmTask?.cancel()
        voiceConfirmTask = nil
        voiceSearch.stopSilently()
        glassesSession.stopListening()
        voicePath = .none
        voiceListening = false
    }

    /// Guía de voz mejorada: solo si sonó la básica (hay de dónde
    /// mejorar), con la voz audible (no silenciada) y una sola vez.
    /// iOS no deja abrir la página de Voces desde la app: la tarjeta
    /// lleva los pasos exactos en el idioma del dispositivo.
    func acknowledgeVoiceUpgrade() {
        UserDefaults.standard.set(true, forKey: voiceUpgradeSeenKey)
        showVoiceUpgrade = false
    }

    func snoozeVoiceUpgrade() {
        showVoiceUpgrade = false
    }

    private func maybePromptVoiceUpgrade() {
        guard !UserDefaults.standard.bool(forKey: voiceUpgradeSeenKey),
              !speaker.isMuted,
              Speaker.isBasicVoice(for: Phrasebook.languageCode())
        else { return }
        showVoiceUpgrade = true
    }

    /// Entrada por nombre (texto o voz): intención explícita, se habla
    /// aunque coincida con algo ya mostrado.
    func searchByName(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        lastResult = nil
        nameResults = []
        nameResultsUntil = nil
        Task { await runNameSearch(query) }
    }

    /// Flujo por nombre: clasifica/expande → busca cada término en la
    /// base real filtrando por ciudad → agrupa por EAN → resuelve con el
    /// mismo camino del escaneo. Sin filas reales: "no encontrado".
    private func runNameSearch(_ query: String) async {
        guard let location = await currentLocation() else {
            scanState = .noLocation
            return
        }
        isLookingUp = true
        defer { isLookingUp = false }
        updatePlaceName(for: location)
        let city = await cityName(for: location)
        let terms = await expandQuery(query, city: city)
        var seenEANs = Set<String>()
        var collected: [StorePrice] = []
        var firstError: Error?
        for term in terms {
            do {
                let rows = try await store.products(matching: term, city: city)
                collected += rows.filter { !seenEANs.contains($0.ean) }
                seenEANs.formUnion(rows.map(\.ean))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        let results = resolveNameRows(
            collected,
            userLat: location.coordinate.latitude,
            userLon: location.coordinate.longitude
        )
        guard !results.isEmpty else {
            if firstError != nil, collected.isEmpty {
                scanState = .error(firstError!.localizedDescription)
            } else {
                scanState = .notFoundNearby
            }
            return
        }
        nameResults = results
        nameResultsUntil = Date().addingTimeInterval(8)
        scanState = .idle
        speaker.speakNameResults(results)
        maybePromptVoiceUpgrade()
        if glassesConnected, let first = results.first {
            await glassesSession.showResult(first)
        }
    }

    /// FoundationModels si está disponible (iOS 26 + Apple Intelligence);
    /// si no, respaldo local sin red. La IA genera términos, nunca precios.
    private func expandQuery(_ query: String, city: String?) async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *),
           let plan = await FoundationQueryExpander.plan(for: query, city: city),
           !plan.terms.isEmpty
        {
            return plan.terms
        }
        #endif
        let local = LocalQueryExpander.terms(for: query)
        return local.isEmpty ? [query].compactMap(cleanTerm) : local
    }

    /// Ciudad para filtrar por retailer_stores.city_name: una sola
    /// geocodificación por búsqueda (con tope de 4 s), separada de la
    /// píldora decorativa con throttle.
    private func cityName(for location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            var resumed = false
            CLGeocoder().reverseGeocodeLocation(location) { places, _ in
                guard !resumed else { return }
                resumed = true
                let place = places?.first
                continuation.resume(returning:
                    place?.locality ?? place?.subAdministrativeArea)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// La cámara corre siempre que la app está abierta; sin botones.
    /// Además arranca el GPS continuo para que cada escaneo use un fix
    /// ya convergido en vez de esperar 6 segundos.
    func startCamera() {
        if !didLogStartup {
            didLogStartup = true
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"
            let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"
            NSLog("[EANShopper] arranque v\(v) build \(b) tag \(Self.buildTag) idioma=\(Phrasebook.languageCode())")
        }
        if cameraSource == .glasses {
            glassesSession.startCameraStream()
        } else {
            scanner.start()
        }
        // Permiso explícito al abrir (si ya se otorgó antes, no molesta)
        // para que el GPS converja mientras apuntas, no al escanear.
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
        startWatchdog()
    }

    func stopCamera() {
        scanner.stop()
        locationManager.stopUpdatingLocation()
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Vigilante único: cada 0,5 s revisa si la cámara dejó de mirar el
    /// EAN. Tras 1,5 s sin avistamientos limpia pantalla y voz.
    private var watchdogTask: Task<Void, Never>?

    /// Avistamiento de un EAN por la cámara. Mismo EAN a la vista: no se
    /// repite lookup ni voz.
    func noteEANSeen(_ ean: String) {
        lastSeenEAN = ean
        lastSeenAt = Date()
        lastEAN = ean
        // La cámara toma el mando: oculta resultados por nombre.
        nameResults = []
        nameResultsUntil = nil
        // Un avistamiento de cámara cancela la retención manual:
        // el flujo vuelve a limpieza de 1,5 s.
        manualHoldUntil = nil
        if ean != lastProcessedEAN {
            lastProcessedEAN = ean
            Task { await handleEAN(ean) }
        }
    }

    /// Retención de 8 s solo para ingreso manual: la cámara sigue
    /// con su limpieza de 1,5 s.
    private var manualHoldUntil: Date?

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Resultados por nombre: se ocultan tras 8 s.
                    if !self.nameResults.isEmpty,
                       let until = self.nameResultsUntil, Date() >= until
                    {
                        self.nameResults = []
                        self.nameResultsUntil = nil
                        self.speaker.stop()
                        self.scanState = .idle
                        return
                    }
                    guard self.lastSeenEAN != nil,
                          Date().timeIntervalSince(self.lastSeenAt) >= 1.5
                    else { return }
                    // Ingreso manual: no limpiar antes de los 8 s para
                    // que la tarjeta y la voz completen.
                    if let hold = self.manualHoldUntil, Date() < hold { return }
                    self.clearScreen()
                }
            }
        }
    }

    /// Limpia píldora, tarjeta y voz: pantalla lista para escanear.
    private func clearScreen() {
        lastEAN = nil
        lastResult = nil
        lastSeenEAN = nil
        manualHoldUntil = nil
        lastProcessedEAN = nil
        lastSpokenEAN = nil
        scanState = .idle
        speaker.stop()
    }

    /// El lookup usa el GPS ya convergido (instantáneo); solo si no hay
    /// fix decente espera uno fresco. La voz suena solo ante EAN nuevo.
    private func handleEAN(_ ean: String) async {
        guard let location = await currentLocation() else {
            scanState = .noLocation
            return
        }
        isLookingUp = true
        defer { isLookingUp = false }
        updatePlaceName(for: location)
        do {
            let prices = try await store.prices(forEAN: ean)
            guard let result = resolveScan(
                ean: ean, prices: prices,
                userLat: location.coordinate.latitude,
                userLon: location.coordinate.longitude
            ) else {
                scanState = .notFoundNearby
                return
            }
            // Si la cámara ya miró a otro lado, el resultado tardío se
            // descarta: no pinta tarjeta ni habla.
            guard ean == lastProcessedEAN,
                  Date().timeIntervalSince(lastSeenAt) < 1.5
            else { return }
            lastResult = result
            scanState = .idle
            if ean != lastSpokenEAN {
                lastSpokenEAN = ean
                speaker.speak(result)
                maybePromptVoiceUpgrade()
            }
            if glassesConnected {
                await glassesSession.showResult(result)
            }
            refineWithBetterFix(ean: ean, prices: prices, shownStoreId: result.nearest.storeId)
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    /// Refinamiento en segundo plano: si en 5 s llega un fix fino (≤50 m)
    /// que cambia la tienda ganadora, actualiza la tarjeta en silencio
    /// (el EAN no cambió, así que no se re-habla).
    private func refineWithBetterFix(
        ean: String, prices: [StorePrice], shownStoreId: String
    ) {
        Task {
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard ean == self.lastProcessedEAN,
                      let fine = self.trackingLocation,
                      fine.horizontalAccuracy >= 0, fine.horizontalAccuracy <= 50,
                      Date().timeIntervalSince(fine.timestamp) < 30,
                      let refined = resolveScan(
                          ean: ean, prices: prices,
                          userLat: fine.coordinate.latitude,
                          userLon: fine.coordinate.longitude
                      ),
                      refined.nearest.storeId != shownStoreId
                else { continue }
                await MainActor.run { [weak self] in
                    guard let self, ean == self.lastProcessedEAN else { return }
                    self.lastResult = refined
                }
                return
            }
        }
    }

    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeAt = Date.distantPast

    /// Geocoding con throttle: solo re-pide si te moviste >100 m o pasó
    /// >60 s. Solo alimenta la píldora decorativa, nunca el cálculo.
    private func updatePlaceName(for location: CLLocation) {
        if let previous = lastGeocodedLocation,
           location.distance(from: previous) < 100,
           Date().timeIntervalSince(lastGeocodeAt) < 60
        {
            return
        }
        lastGeocodedLocation = location
        lastGeocodeAt = Date()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let place = placemarks?.first else { return }
            let parts = [
                place.thoroughfare, place.subLocality, place.locality,
            ].compactMap { $0 }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.lastKnownPlace = parts.joined(separator: ", ")
            }
        }
    }

    /// Respuesta inmediata con lo mejor disponible (<30 s, accuracy válida).
    /// Solo si no hay nada usable espera breve (1,5 s) al primer fix.
    /// La precisión fina llega después por refinamiento (ver handleEAN).
    private func currentLocation() async -> CLLocation? {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        guard locationManager.authorizationStatus == .authorizedWhenInUse
            || locationManager.authorizationStatus == .authorizedAlways
        else { return nil }
        if let tracking = trackingLocation,
           tracking.horizontalAccuracy >= 0,
           Date().timeIntervalSince(tracking.timestamp) < 30
        {
            return tracking
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            pendingCollector = LocationCollector { [weak self] location in
                guard let self, !resumed else { return }
                guard let location, location.horizontalAccuracy >= 0 else { return }
                resumed = true
                self.pendingCollector = nil
                continuation.resume(returning: location)
            }
            locationManager.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !resumed else { return }
                resumed = true
                self.pendingCollector = nil
                continuation.resume(returning: self.trackingLocation)
            }
        }
    }
}

/// Recolecta fixes GPS y conserva el flujo hacia el continuador.
struct LocationCollector {
    var onLocation: ((CLLocation?) -> Void)?
}

extension GlassesManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor [weak self] in
            if let last {
                self?.trackingLocation = last
                if last.horizontalAccuracy >= 0 {
                    self?.locationAccuracyM = last.horizontalAccuracy
                    // La píldora se llena al abrir, sin esperar el primer
                    // escaneo (updatePlaceName ya trae su propio throttle).
                    self?.updatePlaceName(for: last)
                }
            }
            self?.pendingCollector?.onLocation?(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        let fallback = manager.location
        Task { @MainActor [weak self] in
            self?.pendingCollector?.onLocation?(fallback)
        }
    }
}
