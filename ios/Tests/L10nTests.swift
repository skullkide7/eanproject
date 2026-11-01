import Foundation
@testable import EANShopper
import XCTest

/// Localización UI: 9 idiomas completos, inglés por defecto,
/// nunca se muestra la clave.
final class L10nTests: XCTestCase {
    private let langs = ["en", "es", "zh", "pt", "de", "ja", "it", "fr", "hi"]

    func testAllLanguagesHaveAllKeys() {
        let keys = Set(L10n.strings["en"]!.keys)
        XCTAssertFalse(keys.isEmpty)
        for lang in langs {
            let langKeys = L10n.strings[lang].map { Set($0.keys) } ?? []
            let missing = keys.subtracting(langKeys)
            XCTAssertTrue(
                missing.isEmpty,
                "\(lang) sin claves: \(missing.sorted())"
            )
        }
    }

    func testUnknownLanguageFallsBackToEnglish() {
        XCTAssertEqual(L10n.t("here", "xx"), L10n.t("here", "en"))
    }

    func testUnknownKeyReturnsKey() {
        XCTAssertEqual(L10n.t("noExiste", "es"), "noExiste")
    }

    func testSpotCheck() {
        XCTAssertEqual(L10n.t("here", "en"), "HERE")
        XCTAssertEqual(L10n.t("here", "es"), "AQUÍ")
        XCTAssertEqual(L10n.t("mute", "en"), "Mute")
        XCTAssertEqual(L10n.t("mute", "es"), "Silencio")
    }
}
