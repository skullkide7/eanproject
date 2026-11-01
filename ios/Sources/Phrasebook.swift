import Foundation

/// Frases deterministas por idioma: SOLO precio y tienda más cercana.
/// Los datos siempre vienen de Supabase; aquí solo vive la plantilla.
/// Idiomas: en, es, zh, pt, de, ja, it, fr, hi. Defecto: inglés.
enum Phrasebook {
    /// Código ISO del idioma del dispositivo (p. ej. "es"), o "en" si no está soportado.
    static func languageCode(
        for locale: Locale = .current
    ) -> String {
        let supported = ["en", "es", "zh", "pt", "de", "ja", "it", "fr", "hi"]
        let code = locale.language.languageCode?.identifier ?? "en"
        return supported.contains(code) ? code : "en"
    }

    /// Locale de voz para AVSpeechSynthesizer según el idioma elegido.
    static func voiceLocale(for languageCode: String) -> Locale {
        switch languageCode {
        case "es": return Locale(identifier: "es-ES")
        case "zh": return Locale(identifier: "zh-CN")
        case "pt": return Locale(identifier: "pt-BR")
        case "de": return Locale(identifier: "de-DE")
        case "ja": return Locale(identifier: "ja-JP")
        case "it": return Locale(identifier: "it-IT")
        case "fr": return Locale(identifier: "fr-FR")
        case "hi": return Locale(identifier: "hi-IN")
        default: return Locale(identifier: "en-NZ")
        }
    }

    /// Formato exacto de búsqueda por nombre: prefijo + nombre real de
    /// la base + precio + cadena/tienda + distancia. Sin resumen que
    /// mezcle productos: se repite una vez por cada coincidencia real.
    static func namePhrase(for result: ScanResult, languageCode: String) -> String {
        let prefix = L10n.t("foundPrefix", languageCode)
        let price = "\(result.nearest.effectivePrice) \(result.nearest.currency)"
        let distance = ShopFormat.distance(km: result.nearestDistanceKm)
        return "\(prefix): \(result.productName), \(price), " +
            "\(result.nearest.chainName) \(result.nearest.storeName), \(distance)."
    }

    static func phrase(for result: ScanResult, languageCode: String) -> String {
        let price = "\(result.nearest.effectivePrice) \(result.nearest.currency)"
        let store = result.nearest.storeName
        switch languageCode {
        case "es":
            return "\(result.productName): \(price) en \(store)."
        case "zh":
            return "\(result.productName)：\(store)，\(price)。"
        case "pt":
            return "\(result.productName): \(price) em \(store)."
        case "de":
            return "\(result.productName): \(price) bei \(store)."
        case "ja":
            return "\(result.productName)は\(store)で\(price)です。"
        case "it":
            return "\(result.productName): \(price) presso \(store)."
        case "fr":
            return "\(result.productName) : \(price) chez \(store)."
        case "hi":
            return "\(result.productName): \(store) में \(price)。"
        default:
            return "\(result.productName): \(price) at \(store)."
        }
    }
}
