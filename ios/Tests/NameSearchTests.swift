import CoreLocation
import Foundation
@testable import EANShopper
import XCTest

/// Buscar por nombre: agrupar por EAN con el mismo camino del escaneo,
/// descartar filas sin nombre real, expansión local y formato de frase.
final class NameSearchTests: XCTestCase {
    private struct FakeStore: PriceStore {
        let rows: [StorePrice]
        func prices(forEAN ean: String) async throws -> [StorePrice] {
            rows.filter { $0.ean == ean }
        }
        func products(matching term: String, city: String?) async throws -> [StorePrice] {
            rows.filter {
                $0.productName.localizedCaseInsensitiveContains(term)
                    && (city == nil || $0.cityName == city)
            }
        }
    }

    private func row(
        ean: String, name: String, amount: String,
        store: String, city: String = "Wellington",
        lat: Double, lon: Double
    ) -> StorePrice {
        StorePrice(
            ean: ean, productName: name,
            price: Decimal(string: amount, locale: Locale(identifier: "en_US"))!,
            promoPrice: nil, currency: "NZD", storeId: store,
            storeName: store, chainName: "c",
            cityName: city, lat: lat, lon: lon
        )
    }

    func testGroupsByEANAndReusesScanResolution() async throws {
        let store = FakeStore(rows: [
            row(ean: "e1", name: "San Remo Spaghetti 500g", amount: "2.50",
                store: "near", lat: -41.315, lon: 174.797),
            row(ean: "e1", name: "San Remo Spaghetti 500g", amount: "2.80",
                store: "mid", lat: -41.330, lon: 174.780),
            row(ean: "e2", name: "Vetta Spaghetti 500g", amount: "1.99",
                store: "near2", lat: -41.320, lon: 174.800),
        ])
        let rows = try await store.products(matching: "spaghetti", city: "Wellington")
        let results = resolveNameRows(
            rows, userLat: -41.314, userLon: 174.796)
        XCTAssertEqual(results.count, 2)
        // Ordenados por cercanía y cada uno con su nearest del escaneo.
        XCTAssertEqual(results[0].ean, "e1")
        XCTAssertEqual(results[1].ean, "e2")
        XCTAssertEqual(results[0].nearest.storeId, "near")
        XCTAssertEqual(results[0].nearby.map(\.store.storeId), ["mid"])
    }

    func testRowsWithoutRealNameAreDropped() {
        let rows = [
            row(ean: "e1", name: "   ", amount: "1.00",
                store: "s", lat: -41.3, lon: 174.7),
            row(ean: "e2", name: "Pams Pasta 500g", amount: "1.50",
                store: "s", lat: -41.3, lon: 174.7),
        ]
        let results = resolveNameRows(rows, userLat: -41.3, userLon: 174.7)
        XCTAssertEqual(results.map(\.ean), ["e2"])
    }

    func testLocalExpanderFindsEnglishLabelTerms() {
        let terms = LocalQueryExpander.terms(for: "¿cuánto cuestan los tallarines?")
        XCTAssertTrue(terms.contains("pasta"))
        XCTAssertFalse(terms.contains("cuánto"))
        XCTAssertFalse(terms.contains("los"))
    }

    func testCleanTermStripsWildcards() {
        XCTAssertNil(cleanTerm("*"))
        XCTAssertEqual(cleanTerm("pasta%"), "pasta")
        XCTAssertNil(cleanTerm(" a "))
    }

    func testNamePhraseFormat() {
        let result = ScanResult(
            ean: "e", productName: "San Remo Spaghetti 500g",
            nearest: row(ean: "e", name: "San Remo Spaghetti 500g",
                         amount: "2.50", store: "PAK'nSAVE Kilbirnie",
                         lat: -41.315, lon: 174.797),
            nearestDistanceKm: 0.35, nearby: []
        )
        let es = Phrasebook.namePhrase(for: result, languageCode: "es")
        XCTAssertTrue(es.hasPrefix("Encontré este producto que corresponde a lo que pediste:"))
        XCTAssertTrue(es.contains("San Remo Spaghetti 500g"))
        XCTAssertTrue(es.contains("PAK'nSAVE Kilbirnie"))
        let en = Phrasebook.namePhrase(for: result, languageCode: "en")
        XCTAssertTrue(en.hasPrefix("I found this product matching what you asked for:"))
    }

#if canImport(FoundationModels)
    func testFoundationPlanParsing() {
        let plan = FoundationQueryExpander.parsePlan(from:
            #"{"type": "generic", "terms": ["San Remo", "pasta"]}"#)
        XCTAssertEqual(plan?.kind, .generic)
        XCTAssertEqual(plan?.terms, ["San Remo", "pasta"])
        XCTAssertNil(FoundationQueryExpander.parsePlan(from: "sin json"))
        XCTAssertNil(FoundationQueryExpander.parsePlan(from:
            #"{"type": "generic", "terms": []}"#))
    }
#endif
}
