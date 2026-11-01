import Foundation

/// Configuración del backend. Se rellena al completar la Fase 1.
enum BackendConfig {
    static let supabaseURL = URL(
        string: "https://tfunbodhnkhlpvtckivk.supabase.co")!
    static let anonKey = "sb_publishable_qv3YMcd25_BzOh_bTxfjFg_scrHXxfp"
    static var isConfigured: Bool {
        !anonKey.contains("SUPABASE_ANON_KEY")
    }
}

private struct SupabasePriceRow: Decodable {
    let ean: String
    let price: Decimal
    let promo_price: Decimal?
    let currency: String
    let product_name: String?
    let store_id: String
    let retailer_stores: SupabaseStoreRow?
}

private struct SupabaseStoreRow: Decodable {
    let name: String
    let chain_name: String
    let city_name: String
    let lat: Double
    let lon: Double
}

/// Implementación real contra Supabase REST (PostgREST + FK embed).
struct LiveSupabaseStore: PriceStore {
    /// Calienta la conexión TLS en segundo plano tras abrir la app para
    /// que el primer escaneo no pague el handshake (~2 s).
    static func prewarm() async {
        guard BackendConfig.isConfigured else { return }
        var components = URLComponents(
            url: BackendConfig.supabaseURL
                .appendingPathComponent("rest/v1/product_prices"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "select", value: "ean"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(BackendConfig.anonKey)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    func prices(forEAN ean: String) async throws -> [StorePrice] {
        guard BackendConfig.isConfigured else { throw PriceStoreError.notConfigured }
        var components = URLComponents(
            url: BackendConfig.supabaseURL
                .appendingPathComponent("rest/v1/product_prices"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ean", value: "eq.\(ean)"),
            URLQueryItem(name: "stock", value: "is.true"),
            URLQueryItem(name: "select", value:
                "ean,price,promo_price,currency,product_name,store_id," +
                "retailer_stores(name,chain_name,city_name,lat,lon)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(BackendConfig.anonKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PriceStoreError.lookupFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let rows = try JSONDecoder().decode([SupabasePriceRow].self, from: data)
        return rows.compactMap { row in
            guard let store = row.retailer_stores else { return nil }
            return StorePrice(
                ean: row.ean, productName: row.product_name ?? ean,
                price: row.price, promoPrice: row.promo_price,
                currency: row.currency, storeId: row.store_id,
                storeName: store.name, chainName: store.chain_name,
                cityName: store.city_name, lat: store.lat, lon: store.lon)
        }
    }

    /// Búsqueda por texto sobre product_name (usa el índice trigram de
    /// Supabase; el `ilike` con comodín inicial sin índice da timeout
    /// en 1,7 M de filas). Filtra por ciudad de la tienda cuando se
    /// conoce. Descarta filas sin product_name real: una fila con
    /// precio pero sin nombre no sirve para buscar por nombre.
    func products(matching term: String, city: String?) async throws -> [StorePrice] {
        guard BackendConfig.isConfigured else { throw PriceStoreError.notConfigured }
        guard let clean = cleanTerm(term) else { return [] }
        var components = URLComponents(
            url: BackendConfig.supabaseURL
                .appendingPathComponent("rest/v1/product_prices"),
            resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "product_name", value: "ilike.*\(clean)*"),
            URLQueryItem(name: "select", value:
                "ean,price,promo_price,currency,product_name,store_id," +
                "retailer_stores!inner(name,chain_name,city_name,lat,lon)"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let city, !city.isEmpty {
            queryItems.append(URLQueryItem(
                name: "retailer_stores.city_name", value: "ilike.*\(city)*"))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(BackendConfig.anonKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PriceStoreError.lookupFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let rows = try JSONDecoder().decode([SupabasePriceRow].self, from: data)
        return rows.compactMap { row in
            guard let store = row.retailer_stores,
                  let name = row.product_name?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return StorePrice(
                ean: row.ean, productName: name,
                price: row.price, promoPrice: row.promo_price,
                currency: row.currency, storeId: row.store_id,
                storeName: store.name, chainName: store.chain_name,
                cityName: store.city_name, lat: store.lat, lon: store.lon)
        }
    }
}

/// Muestra local para desarrollar la UI sin base de datos.
struct SampleStore: PriceStore {
    func prices(forEAN ean: String) async throws -> [StorePrice] {
        [
            StorePrice(
                ean: ean, productName: "Sample Potato Chips 150g",
                price: 1.99, promoPrice: nil, currency: "NZD",
                storeId: "NZ_paknsave_sample_001",
                storeName: "PAK'nSAVE Sample", chainName: "PAK'nSAVE",
                cityName: "Wellington", lat: -41.2924, lon: 174.7787),
            StorePrice(
                ean: ean, productName: "Sample Potato Chips 150g",
                price: 2.49, promoPrice: 2.19, currency: "NZD",
                storeId: "NZ_new_world_sample_001",
                storeName: "New World Sample", chainName: "New World",
                cityName: "Wellington", lat: -41.2889, lon: 174.7772),
        ]
    }

    func products(matching term: String, city: String?) async throws -> [StorePrice] {
        guard let clean = cleanTerm(term) else { return [] }
        let rows = try await prices(forEAN: "sample")
        return rows.filter { row in
            row.productName.localizedCaseInsensitiveContains(clean)
                && (city == nil || city!.isEmpty
                    || row.cityName.localizedCaseInsensitiveContains(city!))
        }
    }
}
