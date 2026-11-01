import Foundation

/// Formato de precios y distancias para la UI.
/// Precios estilo "NZ$2,29" según el idioma del dispositivo;
/// distancias en metros bajo 1 km ("3349m") y en km sobre eso.
enum ShopFormat {
    private static var formatters: [String: NumberFormatter] = [:]

    static func price(_ value: Decimal, currency: String) -> String {
        let key = "\(currency)-\(Locale.current.identifier)"
        if formatters[key] == nil {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.locale = Locale.current
            formatters[key] = formatter
        }
        return formatters[key]?.string(from: value as NSDecimalNumber)
            ?? "\(value) \(currency)"
    }

    static func distance(km: Double) -> String {
        if km < 1.0 {
            return "\(Int((km * 1000).rounded()))m"
        }
        if km < 10.0 {
            return String(format: "%.1f km", km)
        }
        return "\(Int(km.rounded())) km"
    }
}
