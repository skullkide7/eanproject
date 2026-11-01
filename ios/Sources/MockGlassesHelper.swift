import Foundation

#if DEBUG && canImport(MWDATMockDevice)
import MWDATMockDevice
#if canImport(MWDATMockDeviceTestClient)
import MWDATMockDeviceTestClient
#endif

/// Enciende MockDeviceKit y empareja lentes Ray-Ban Meta simulados.
/// Solo compilado en DEBUG; nunca en Release.
enum MockGlassesHelper {
    private static var pairedMock: MockGlasses?
    /// Solo en simulación: permite re-afirmar el feed al arrancar.
    static var liveFeedWanted = false
    /// Puerto del servidor de test (inyectar eventos). Sin arrancarlo,
    /// el cliente apunta al puerto 0 y la inyección falla.
    private static var testPort: UInt16?

    static func disable() {
        liveFeedWanted = false
        pairedMock = nil
        testPort = nil
        MockDeviceKit.shared.disable()
    }

    static func enableAndPair() {
        MockDeviceKit.shared.enable()
        do {
            // Sin powerOn/unfold/don el mock nunca es "elegible" y
            // createSession falla con noEligibleDevice.
            let mock = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
            pairedMock = mock
            mock.powerOn()
            mock.unfold()
            mock.don()
            applyFeed(to: mock)
        } catch {
            NSLog("[EANShopper] No se pudo emparejar lentes simulados: \(error)")
        }
        Task {
            testPort = try? await MockDeviceKit.shared.startTestServer()
            NSLog("[EANShopper] servidor test mock en puerto \(testPort ?? 0)")
        }
    }

    /// Feed del mock: video empaquetado si existe (demo
    /// determinista), si no la cámara en vivo del iPhone.
    private static func applyFeed(to mock: MockGlasses) {
        if let url = Bundle.main.url(forResource: "test_video", withExtension: "mp4") {
            mock.services.camera.setCameraFeed(fileURL: url)
            NSLog("[EANShopper] feed del mock: video empaquetado")
        } else {
            mock.services.camera.setCameraFeed(cameraFacing: .back)
        }
    }

    /// Re-afirma el feed (el set inicial a veces queda en negro;
    /// reintentarlo con el stream ya en marcha lo levanta).
    static func refreshPhoneFeed() {
        guard liveFeedWanted, let mock = pairedMock else { return }
        applyFeed(to: mock)
        NSLog("[EANShopper] feed del mock re-afirmado")
    }

    /// Inyecta un dictado simulado en el mock emparejado (parcial y
    /// final): verifica el camino lentes → texto → búsqueda sin hardware.
    static func injectTranscription(_ text: String) {
#if DEBUG && canImport(MWDATMockDeviceTestClient)
        guard let mock = pairedMock else {
            NSLog("[EANShopper] inyección dictado: sin mock emparejado")
            return
        }
        let deviceId = mock.deviceIdentifier
        Task {
            if testPort == nil {
                testPort = try? await MockDeviceKit.shared.startTestServer()
            }
            guard let port = testPort, port != 0 else {
                NSLog("[EANShopper] inyección dictado: sin servidor de test")
                return
            }
            let client = MockDeviceTestClient(port: port)
            _ = await client.simulateTranscription(
                deviceId: deviceId, text: text, isFinal: false)
            try? await Task.sleep(for: .seconds(1))
            let ok = await client.simulateTranscription(
                deviceId: deviceId, text: text, isFinal: true)
            NSLog("[EANShopper] inyección dictado: \(ok ? "ok" : "falló")")
        }
#else
        NSLog("[EANShopper] inyección dictado: sin cliente de test")
#endif
    }

    /// Inyecta una pulsación del botón de acción en el mock emparejado:
    /// recorre el mismo camino que el hardware real (evento → voz).
    static func injectActionButton() {
#if DEBUG && canImport(MWDATMockDeviceTestClient)
        guard let mock = pairedMock else {
            NSLog("[EANShopper] inyección botón: sin mock emparejado")
            return
        }
        let deviceId = mock.deviceIdentifier
        Task {
            if testPort == nil {
                testPort = try? await MockDeviceKit.shared.startTestServer()
            }
            guard let port = testPort, port != 0 else {
                NSLog("[EANShopper] inyección botón: sin servidor de test")
                return
            }
            let ok = await MockDeviceTestClient(port: port)
                .inputAction(deviceId: deviceId)
            NSLog("[EANShopper] inyección botón acción: \(ok ? "ok" : "falló")")
        }
#else
        NSLog("[EANShopper] inyección botón: sin cliente de test")
#endif
    }
}

#else

/// Sin MockDeviceKit: no hace nada (compilación Release o sin SDK).
enum MockGlassesHelper {
    static var liveFeedWanted = false
    static func disable() {}
    static func enableAndPair() {}
    static func refreshPhoneFeed() {}
    static func injectActionButton() {}
    static func injectTranscription(_ text: String) {}
}

#endif
