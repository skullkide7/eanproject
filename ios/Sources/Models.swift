import CoreLocation
import Foundation

/// Precio de un EAN en una tienda concreta, tal como viene de Supabase.
struct StorePrice: Identifiable, Equatable {
    var id: String { storeId }
    let ean: String
    let productName: String
    let price: Decimal
    let promoPrice: Decimal?
    let currency: String
    let storeId: String
    let storeName: String
    let chainName: String
    let cityName: String
    let lat: Double
    let lon: Double

    var effectivePrice: Decimal { promoPrice ?? price }

    func distanceKm(from location: CLLocation) -> Double {
        let store = CLLocation(latitude: lat, longitude: lon)
        return location.distance(from: store) / 1000.0
    }
}

/// Una alternativa cercana con su distancia.
struct NearbyStore: Equatable {
    let store: StorePrice
    let distanceKm: Double
}

/// Resultado de un escaneo: tienda más cercana + alternativas a ≤5 km.
struct ScanResult: Equatable {
    let ean: String
    let productName: String
    let nearest: StorePrice
    let nearestDistanceKm: Double
    /// Otras tiendas a ≤5 km, ordenadas por precio y luego distancia.
    let nearby: [NearbyStore]
}
