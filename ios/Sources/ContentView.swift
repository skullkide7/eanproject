import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

/// Cámara a pantalla completa con overlays:
/// píldora de ubicación, EAN detectado, tarjeta AQUÍ y panel CERCA.
struct ContentView: View {
    @EnvironmentObject var glasses: GlassesManager
    @State private var showMenu = false
    @State private var showManualEAN = false
    @State private var manualEAN = ""
    @State private var nameQuery = ""

    var body: some View {
        ZStack {
            if glasses.glassesConnected {
                // Sin frame congelado: imagen de lentes mientras la
                // fuente es el stream (simulado o real).
                glassesPlaceholder
            } else {
                CameraPreview(previewLayer: glasses.scanner.previewLayer)
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                topBar
                if let error = glasses.glassesError, !glasses.glassesConnected {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                // Botón físico de los lentes: la pregunta por voz se pide
                // y se muestra aquí, sin salir de la pantalla principal.
                if glasses.voiceListening {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.red)
                        Text(glasses.voiceTranscript.isEmpty
                            ? L10n.t("listening") : glasses.voiceTranscript)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if glasses.isLookingUp {
                    ProgressView()
                        .tint(.white)
                        .padding(6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                }
                resultOverlay
            }
            .padding()
            // Panel de vidrio sobre todo: se cierra tocando fuera.
            if showMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) { showMenu = false }
                    }
                glassMenuPanel
            }
        }
        .preferredColorScheme(.dark)
        // Retorno desde la app de Meta AI: completa registro y permisos DAT.
        .onOpenURL { url in
            #if canImport(MWDATCore)
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
            else { return }
            Task {
                do {
                    // Con onRegistrationRequest también se atiende el
                    // registro iniciado desde la app de Meta AI
                    // (handleUrl solo falla en ese caso).
                    _ = try await Wearables.shared.handleUrl(url) { request in
                        Task {
                            try? await request.continueRegistration()
                        }
                    }
                } catch {
                    NSLog("[EANShopper] handleUrl falló: \(String(describing: error))")
                }
            }
            #endif
        }
        .sheet(isPresented: $showManualEAN) {
            manualEANView
        }
        .sheet(isPresented: $glasses.openNameSearch) {
            nameSearchView
        }
        .sheet(isPresented: $glasses.showVoiceUpgrade) {
            voiceUpgradeView
        }
        .task {
            // Arranque mínimo: cámara inmediata + precalentado de red en
            // fondo. El SDK de lentes se configura solo al conectar.
            glasses.startCamera()
            glasses.prewarmBackend()
        }
        .onDisappear {
            glasses.stopCamera()
        }
    }

    // MARK: - Barra superior

    private var topBar: some View {
        HStack(alignment: .top) {
            locationPill
            if glasses.glassesConnected {
                glassesPill
            }
            Spacer()
            if glasses.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            menuButton
        }
    }

    /// Indicador visible de fuente: sin esto, conectar no se nota.
    private var glassesPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "eyeglasses")
            Text("Meta Glasses")
                .bold()
        }
        .font(.subheadline)
        .foregroundStyle(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Imagen de lentes en vez del frame congelado, con botón para
    /// volver a la cámara del iPhone sin pasar por el menú.
    private var glassesPlaceholder: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "eyeglasses")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                Text("Meta Glasses")
                    .font(.title2)
                    .bold()
                    .foregroundStyle(.white)
                Text(L10n.t("viewingThrough"))
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer()
                Button(L10n.t("useIPhone")) {
                    glasses.disconnectGlasses()
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }

    /// Dirección + precisión GPS ("±25 m"): si el número es grande,
    /// el nearest puede fallar y se ve por qué.
    private var placeLine: String {
        if let accuracy = glasses.locationAccuracyM {
            return "\(glasses.lastKnownPlace) · ±\(Int(accuracy.rounded())) m"
        }
        return glasses.lastKnownPlace
    }

    private var locationPill: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.green)
                Text("eanai")
                    .bold()
            }
            .font(.subheadline)
            Text(placeLine)
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var menuButton: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { showMenu.toggle() }
            // Abrir opciones también descarta las tarjetas por nombre.
            glasses.dismissNameResults()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .scaleEffect(showMenu ? 0.9 : 1.0)
        }
        .buttonStyle(GlassPressStyle())
        .sensoryFeedback(.selection, trigger: showMenu)
    }

    /// Panel flotante estilo vidrio: cada opción anima al pulsarla.
    private var glassMenuPanel: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $glasses.isMuted) {
                        HStack {
                            Image(systemName: glasses.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            Text(glasses.isMuted ? L10n.t("listen") : L10n.t("mute"))
                        }
                    }
                        .tint(.green)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    Divider().background(.white.opacity(0.2))
                    menuAction(L10n.t("manualEAN")) {
                        showManualEAN = true
                    }
                    menuAction(L10n.t("searchByName")) {
                        glasses.openNameSearch = true
                    }
                    if glasses.glassesConnected, glasses.simActive {
                        menuAction(L10n.t("exitSim")) {
                            glasses.disconnectGlasses()
                        }
                        #if DEBUG
                        menuAction(L10n.t("testButton")) {
                            glasses.testActionButton()
                        }
                        menuAction(L10n.t("testSpeech")) {
                            glasses.testSpeechTranscription()
                        }
                        #endif
                    } else if glasses.glassesConnected {
                        menuAction(L10n.t("disconnect")) {
                            glasses.disconnectGlasses()
                        }
                    } else {
                        if glasses.isConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.green)
                                Text(L10n.t("connecting"))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.t("cancel")) {
                                    glasses.cancelConnection()
                                }
                                .buttonStyle(GlassPressStyle())
                                .sensoryFeedback(.selection, trigger: glasses.isConnecting)
                                .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        menuAction(L10n.t("connect")) {
                            glasses.connectGlasses()
                        }
                        .disabled(glasses.isConnecting)
                        #if DEBUG
                        menuAction(L10n.t("simulate")) {
                            glasses.simulateGlasses()
                        }
                        .disabled(glasses.isConnecting)
                        menuAction(L10n.t("testDisplay")) {
                            glasses.testDisplay()
                        }
                        menuAction(L10n.t("testButton")) {
                            glasses.testActionButton()
                        }
                        #endif
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: 220)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 12)
                .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                .padding(.trailing, 16)
            }
            Spacer()
        }
        .padding(.top, 76)
    }

    /// Fila del panel: cierra el menú y ejecuta con feedback háptico.
    private func menuAction(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            withAnimation(.spring(duration: 0.25)) { showMenu = false }
        }
        .buttonStyle(GlassPressStyle())
        .sensoryFeedback(.impact, trigger: showMenu)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Animación de presión consistente (formato vidrio).
    private struct GlassPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .opacity(configuration.isPressed ? 0.6 : 1.0)
                .animation(.spring(duration: 0.2), value: configuration.isPressed)
        }
    }

    // MARK: - Resultado

    @ViewBuilder
    private var resultOverlay: some View {
        switch glasses.scanState {
        case .idle:
            // Con lentes puestos el precio va al display, no al teléfono.
            if !glasses.glassesConnected, !glasses.nameResults.isEmpty {
                nameResultsCard(results: glasses.nameResults)
                    // Tocar una tarjeta vuelve a la cámara sin precios.
                    .onTapGesture { glasses.dismissNameResults() }
            } else if !glasses.glassesConnected, let result = glasses.lastResult {
                HStack(alignment: .bottom, spacing: 10) {
                    hereCard(result: result)
                    nearbyPanel(result: result)
                }
            }
        case .noLocation:
            errorPill(L10n.t("noGPS"))
        case .notFoundNearby:
            errorPill(L10n.t("notFound"))
        case .error(let message):
            errorPill("\(L10n.t("error")): \(message)")
        case .scanning:
            EmptyView()
        }
    }

    private func errorPill(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Izquierda: tienda más cercana.
    private func hereCard(result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
                Text("\(L10n.t("here")) · \(ShopFormat.distance(km: result.nearestDistanceKm))")
                    .font(.caption.bold())
            }
            Text(result.productName)
                .font(.headline)
            Text(ShopFormat.price(
                result.nearest.effectivePrice,
                currency: result.nearest.currency
            ))
            .font(.largeTitle.bold())
            .foregroundStyle(.green)
            Text(result.nearest.chainName.uppercased())
                .font(.subheadline.bold())
            Text(result.nearest.storeName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.blue, lineWidth: 1.5)
        )
    }

    /// Derecha: cercanas ordenadas de barato a caro.
    private func nearbyPanel(result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("nearbyHeader"))
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            if result.nearby.isEmpty {
                Text(L10n.t("noAlternatives"))
                    .font(.caption)
            } else {
                ForEach(result.nearby.prefix(3), id: \.store.storeId) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.store.storeName)
                            .font(.subheadline.bold())
                        Text(ShopFormat.price(
                            item.store.effectivePrice,
                            currency: item.store.currency
                        ))
                        .font(.headline)
                        .foregroundStyle(.green)
                        Text(ShopFormat.distance(km: item.distanceKm))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Buscar por nombre

    /// Una tarjeta por cada coincidencia real: nombre + precio +
    /// cadena/tienda + distancia, mismo vidrio que el resto.
    private func nameResultsCard(results: [ScanResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(results.prefix(5), id: \.ean) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.productName)
                        .font(.headline)
                    Text(ShopFormat.price(
                        result.nearest.effectivePrice,
                        currency: result.nearest.currency
                    ))
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                    Text("\(result.nearest.chainName.uppercased()) · \(result.nearest.storeName)")
                        .font(.subheadline.bold())
                    Text(ShopFormat.distance(km: result.nearestDistanceKm))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Buscador por voz (por defecto, escucha sola al abrir) o texto
    /// como alternativa. La voz se envía 1,5 s después del silencio.
    private var nameSearchView: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    modeButton(
                        title: L10n.t("nameTitle"),
                        active: glasses.nameSearchVoiceMode
                    ) {
                        glasses.switchToVoiceMode()
                    }
                    modeButton(
                        title: L10n.t("textTab"),
                        active: !glasses.nameSearchVoiceMode
                    ) {
                        glasses.switchToTextMode()
                    }
                }
                if glasses.nameSearchVoiceMode {
                    voiceModeView
                } else {
                    textModeView
                }
                Spacer()
            }
            .padding()
            .navigationTitle(L10n.t("nameTitle"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.5)])
        .onAppear {
            nameQuery = ""
            glasses.onNameSearchAppear()
        }
        .onDisappear {
            glasses.closeVoiceScreen()
        }
    }

    private func modeButton(
        title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(GlassPressStyle())
            .sensoryFeedback(.selection, trigger: active)
            .font(.subheadline.bold())
            .foregroundStyle(active ? Color.green : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    active ? .green : .clear, lineWidth: 1.5)
            )
    }

    /// Modo voz: escucha sola, muestra lo captado en vivo. Sin botones
    /// para partir: el parcial es "empezó a hablar", el silencio + 1,5 s
    /// envía solo al flujo de buscar por nombre.
    private var voiceModeView: some View {
        VStack(spacing: 10) {
            Image(systemName: glasses.voiceListening ? "mic.fill" : "mic")
                .font(.largeTitle)
                .foregroundStyle(glasses.voiceListening ? .red : .gray)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(Circle())
            Text(glasses.voiceTranscript.isEmpty
                ? L10n.t("listening") : glasses.voiceTranscript)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(
                    glasses.voiceTranscript.isEmpty ? Color.secondary : Color.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    /// Modo texto: alternativa para quien prefiere escribir.
    private var textModeView: some View {
        VStack(spacing: 12) {
            TextField(
                L10n.t("namePlaceholder"),
                text: $nameQuery
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Button(L10n.t("search")) {
                glasses.searchByName(nameQuery)
                glasses.openNameSearch = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(nameQuery.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Voz mejorada

    /// Guía única para descargar la voz neuronal: iOS no deja abrir
    /// la página de Voces desde la app, así que van los pasos exactos.
    private var voiceUpgradeView: some View {
        VStack(spacing: 14) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(L10n.t("voiceUpgradeTitle"))
                .font(.headline)
            Text(L10n.t("voiceUpgradeBody"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.t("voiceUpgradeOK")) {
                glasses.acknowledgeVoiceUpgrade()
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.t("voiceUpgradeLater")) {
                glasses.snoozeVoiceUpgrade()
            }
            .buttonStyle(GlassPressStyle())
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .presentationDetents([.fraction(0.45)])
    }

    // MARK: - EAN manual

    /// Teclado numérico propio estilo vidrio: el teclado del sistema
    /// no se puede vestir, y este evita el foco que nunca abría.
    private var manualEANView: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(manualEAN.isEmpty ? L10n.t("eanPlaceholder") : manualEAN)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(manualEAN.isEmpty ? .gray : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "del"]], id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { key in
                            if key.isEmpty {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 56)
                            } else if key == "del" {
                                keyButton(systemImage: "delete.left") {
                                    if !manualEAN.isEmpty { manualEAN.removeLast() }
                                }
                            } else {
                                keyButton(key) {
                                    if manualEAN.count < 13 { manualEAN.append(key) }
                                }
                            }
                        }
                    }
                }
                Button(L10n.t("search")) {
                    glasses.debugLookup(ean: manualEAN)
                    showManualEAN = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualEAN.isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle(L10n.t("manualTitle"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.7)])
        .onAppear { manualEAN = "" }
    }

    private func keyButton(
        _ title: String? = nil,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title2)
                } else {
                    Text(title ?? "")
                        .font(.title2.bold())
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(GlassPressStyle())
        .sensoryFeedback(.impact, trigger: manualEAN)
    }
}
