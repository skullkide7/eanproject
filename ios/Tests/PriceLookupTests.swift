import CoreLocation
import Foundation
@testable import EANShopper
import XCTest

/// Lógica de resolución y formato: la tienda más cercana va a la
/// izquierda y las alternativas a ≤5 km a la derecha por precio.
final class PriceLookupTests: XCTestCase {
    private func price(
        id: String, amount: String, promo: String? = nil, lat: Double, lon: Double
    ) -> StorePrice {
        StorePrice(
            ean: "9300624005353", productName: "Still Water",
            price: Decimal(string: amount, locale: Locale(identifier: "en_US"))!,
            promoPrice: promo.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US")) },
            currency: "NZD", storeId: id, storeName: id, chainName: "c",
            cityName: "Wellington", lat: lat, lon: lon
        )
    }

    func testNearestGoesLeftAndNearbyWithin5Km() {
        // Usuario en Kilbirnie (-41.314, 174.796 aprox).
        let prices = [
            price(id: "near", amount: "2.29", lat: -41.315, lon: 174.797),
            price(id: "mid", amount: "2.00", lat: -41.330, lon: 174.780),
            price(id: "far", amount: "1.99", lat: -41.000, lon: 174.700),
        ]
        let result = resolveScan(
            ean: "9300624005353", prices: prices,
            userLat: -41.314, userLon: 174.796
        )!
        XCTAssertEqual(result.nearest.storeId, "near")
        XCTAssertEqual(result.nearby.map(\.store.storeId), ["mid"])
    }

    func testPromoCountsAsEffectivePrice() {
        let prices = [
            price(id: "a", amount: "3.00", promo: "1.50", lat: -41.10, lon: 174.70),
            price(id: "b", amount: "2.00", lat: -41.11, lon: 174.71),
        ]
        let result = resolveScan(
            ean: "e", prices: prices, userLat: -41.10, userLon: 174.70)!
        // "a" es la más cercana aunque "b" sea más barata de lista.
        XCTAssertEqual(result.nearest.storeId, "a")
        XCTAssertEqual(result.nearest.effectivePrice, Decimal(string: "1.50")!)
    }

    func testEmptyPricesReturnsNil() {
        XCTAssertNil(resolveScan(ean: "e", prices: [], userLat: 0, userLon: 0))
    }

    func testDistanceTextMetersBelow1Km() {
        XCTAssertEqual(ShopFormat.distance(km: 0.1), "100m")
        XCTAssertEqual(ShopFormat.distance(km: 3.349), "3.3 km")
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        XCTAssertEqual(Phrasebook.languageCode(for: Locale(identifier: "ko-KR")), "en")
        XCTAssertEqual(Phrasebook.languageCode(for: Locale(identifier: "es-CL")), "es")
    }
}
