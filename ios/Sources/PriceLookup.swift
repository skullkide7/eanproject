import CoreLocation
import Foundation

/// Origen de datos de precios. Misma firma para la muestra local y Supabase.
protocol PriceStore {
    func prices(forEAN ean: String) async throws -> [StorePrice]
    /// Filas cuyo product_name contiene el término, opcionalmente
    /// acotadas a una ciudad. Solo filas con product_name real.
    func products(matching term: String, city: String?) async throws -> [StorePrice]
}

enum PriceStoreError: Error {
    case notConfigured
    case lookupFailed(String)
}

/// Distancia haversiana en km (sin depender de CoreLocation para la lógica).
func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let rad = Double.pi / 180.0
    let dLat = (lat2 - lat1) * rad
    let dLon = (lon2 - lon1) * rad
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
    return 6371.0 * 2 * atan2(sqrt(a), sqrt(1 - a))
}

/// Resuelve el resultado de un escaneo: más cercana a la izquierda,
/// alternativas a ≤5 km a la derecha, ordenadas por precio y distancia.
func resolveScan(ean: String, prices: [StorePrice],
                 userLat: Double, userLon: Double) -> ScanResult? {
    guard !prices.isEmpty else { return nil }
    let withDistance = prices.map { ($0, haversineKm(
        lat1: userLat, lon1: userLon, lat2: $0.lat, lon2: $0.lon)) }
    guard let nearestPair = withDistance.min(by: { $0.1 < $1.1 }) else { return nil }
    let nearby = withDistance
        .filter { $0.0.storeId != nearestPair.0.storeId && $0.1 <= 5.0 }
        .sorted {
            if $0.0.effectivePrice != $1.0.effectivePrice {
                return $0.0.effectivePrice < $1.0.effectivePrice
            }
            return $0.1 < $1.1
        }
        .map { NearbyStore(store: $0.0, distanceKm: $0.1) }
    return ScanResult(ean: ean, productName: nearestPair.0.productName,
                      nearest: nearestPair.0, nearestDistanceKm: nearestPair.1,
                      nearby: nearby)
}
