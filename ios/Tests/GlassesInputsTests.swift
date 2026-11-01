import Foundation
@testable import EANShopper
import XCTest

#if canImport(MWDATInputs)
import MWDATInputs

/// Botón físico de los lentes: solo acción (+ respaldo touchpad)
/// arranca la pregunta por voz; la captura jamás.
final class GlassesInputsTests: XCTestCase {
    func testOnlyActionButtonAndTouchpadTrigger() {
        let session = GlassesSession()
        XCTAssertTrue(session.glassesInputTriggersVoiceSearch(
            .button(.action, source: .actionButton, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .button(.action, source: .captureButton, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .button(.action, source: .unknown, timestampMs: 0)))
        XCTAssertTrue(session.glassesInputTriggersVoiceSearch(
            .select(source: .captouch, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .select(source: .neuralBand, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .capture(.shortPress, source: .captureButton, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .capture(.hold, source: .captureButton, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .capture(.doublePress, source: .captureButton, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .nav(direction: .down, source: .captouch, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .back(source: .captouch, timestampMs: 0)))
        XCTAssertFalse(session.glassesInputTriggersVoiceSearch(
            .drag(action: .down, x: 0, y: 0, dx: 0, dy: 0,
                  source: .neuralBandDrag, timestampMs: 0)))
    }
}
#endif

/// Acumulador del dictado: los parciales reemplazan, solo el final
/// se entrega para buscar.
final class SpeechAccumulatorTests: XCTestCase {
    func testPartialsReplaceAndOnlyFinalDelivers() {
        var acc = SpeechAccumulator()
        XCTAssertNil(acc.feed(text: "¿cuánto", isFinal: false))
        XCTAssertEqual(acc.text, "¿cuánto")
        XCTAssertNil(acc.feed(text: "¿cuánto cuestan", isFinal: false))
        XCTAssertEqual(acc.text, "¿cuánto cuestan")
        XCTAssertEqual(
            acc.feed(text: "¿cuánto cuestan los tallarines?", isFinal: true),
            "¿cuánto cuestan los tallarines?")
    }

    func testEmptyFinalDeliversEmpty() {
        var acc = SpeechAccumulator()
        XCTAssertEqual(acc.feed(text: "", isFinal: true), "")
    }
}
