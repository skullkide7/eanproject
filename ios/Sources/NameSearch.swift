import CoreLocation
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Plan de búsqueda por nombre: la IA solo decide QUÉ términos buscar.
/// El precio siempre sale después de una consulta real a product_prices.
struct QueryPlan: Equatable {
    enum Kind: String {
        case specific
        case generic
    }

    let kind: Kind
    let terms: [String]
}

/// Limpia un término para `ilike`: sin comodines inyectables,
/// acotado y nunca vacío.
func cleanTerm(_ raw: String) -> String? {
    let stripped = raw
        .replacingOccurrences(of: "*", with: " ")
        .replacingOccurrences(of: "%", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard stripped.count >= 2 else { return nil }
    return String(stripped.prefix(40))
}

/// Respaldo sin IA: palabras de la pregunta (sin stopwords ES/EN) más
/// sinónimos español→inglés de etiquetas NZ. Sin red, sin key.
enum LocalQueryExpander {
    static let synonyms: [String: [String]] = [
        "tallarines": ["pasta", "spaghetti", "noodles"],
        "fideos": ["noodles", "pasta"],
        "pasta": ["pasta", "spaghetti"],
        "spaghetti": ["spaghetti", "pasta"],
        "noodles": ["noodles"],
        "leche": ["milk"], "milk": ["milk"],
        "pan": ["bread"], "bread": ["bread"],
        "queso": ["cheese"], "cheese": ["cheese"],
        "arroz": ["rice"], "rice": ["rice"],
        "azucar": ["sugar"], "azúcar": ["sugar"], "sugar": ["sugar"],
        "aceite": ["oil"], "oil": ["oil"],
        "cafe": ["coffee"], "café": ["coffee"], "coffee": ["coffee"],
        "te": ["tea"], "té": ["tea"], "tea": ["tea"],
        "agua": ["water"], "water": ["water"],
        "jugo": ["juice"], "juice": ["juice"],
        "cerveza": ["beer"], "beer": ["beer"],
        "vino": ["wine"], "wine": ["wine"],
        "manzana": ["apple"], "apple": ["apple"],
        "platano": ["banana"], "plátano": ["banana"], "banana": ["banana"],
        "pollo": ["chicken"], "chicken": ["chicken"],
        "carne": ["beef"], "beef": ["beef"],
        "pescado": ["fish"], "fish": ["fish"],
        "huevo": ["egg"], "huevos": ["egg"], "egg": ["egg"], "eggs": ["egg"],
        "mantequilla": ["butter"], "butter": ["butter"],
        "yogur": ["yoghurt", "yogurt"], "yogurt": ["yoghurt", "yogurt"],
        "chocolate": ["chocolate"],
        "galleta": ["biscuit"], "galletas": ["biscuits"],
        "galletta": ["biscuit"], "biscuit": ["biscuit"],
        "sopa": ["soup"], "soup": ["soup"],
        "salsa": ["sauce"], "sauce": ["sauce"],
        "tomate": ["tomato"], "tomates": ["tomato"], "tomato": ["tomato"],
        "papa": ["potato"], "papas": ["potato"],
        "patata": ["potato"], "potato": ["potato"],
        "cebolla": ["onion"], "onion": ["onion"],
        "zanahoria": ["carrot"], "carrot": ["carrot"],
        "lechuga": ["lettuce"], "lettuce": ["lettuce"],
        "palta": ["avocado"], "avocado": ["avocado"],
        "helado": ["ice cream"],
        "miel": ["honey"], "honey": ["honey"],
        "sal": ["salt"], "salt": ["salt"],
        "harina": ["flour"], "flour": ["flour"],
        "cereal": ["cereal"], "cereales": ["cereal"],
        "avena": ["oats"], "oats": ["oats"],
        "mermelada": ["jam"], "jam": ["jam"],
        "mayonesa": ["mayonnaise"],
        "ketchup": ["ketchup", "tomato sauce"],
        "mostaza": ["mustard"],
        "atun": ["tuna"], "atún": ["tuna"], "tuna": ["tuna"],
        "arvejas": ["peas"], "peas": ["peas"],
        "choclo": ["corn"], "maiz": ["corn"], "maíz": ["corn"], "corn": ["corn"],
        "porotos": ["beans"], "beans": ["beans"],
        "lentejas": ["lentils"],
        "garbanzos": ["chickpeas"],
        "azucarera": ["sugar"],
        "detergente": ["detergent"],
        "jabon": ["soap"], "jabón": ["soap"], "soap": ["soap"],
        "shampoo": ["shampoo"],
        "papel": ["paper"], "higienico": ["toilet"], "toilet": ["toilet"],
    ]

    static let stopwords: Set<String> = [
        "cuanto", "cuánto", "cuestan", "cuesta", "cuestan", "el", "la",
        "los", "las", "de", "del", "un", "una", "unos", "unas", "precio",
        "precios", "cual", "cuál", "cuales", "es", "son", "me", "puedes",
        "puede", "decir", "dime", "favor", "por", "para", "que", "qué",
        "como", "cómo", "esta", "este", "esto", "hay", "tiene", "tienen",
        "how", "much", "many", "is", "are", "the", "a", "an", "price",
        "prices", "of", "what", "which", "cost", "costs", "does", "do",
        "please", "me", "tell", "there",
    ]

    /// Extrae hasta 6 términos buscables de la pregunta cruda.
    static func terms(for query: String) -> [String] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }
        var out: [String] = []
        for word in words {
            let expansions = synonyms[word] ?? [word]
            for term in expansions {
                if let clean = cleanTerm(term), !out.contains(clean) {
                    out.append(clean)
                }
                if out.count >= 6 { return out }
            }
        }
        return out
    }
}

/// Clasificación y expansión con el modelo on-device de Apple.
/// Solo existe donde el framework compila; en runtime además exige
/// iOS 26+ y disponibilidad del modelo (gate por disponibilidad).
#if canImport(FoundationModels)
enum FoundationQueryExpander {
    @available(iOS 26, *)
    static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Un solo llamado: clasifica y expande. Nil ante cualquier fallo
    /// (sin modelo, sin Apple Intelligence, respuesta inválida) para
    /// que el llamador caiga al respaldo local.
    @available(iOS 26, *)
    static func plan(for query: String, city: String?) async -> QueryPlan? {
        guard isAvailable() else { return nil }
        let instructions = """
        You help search a New Zealand supermarket database (PAK'nSAVE, \
        New World). You NEVER invent prices. Reply with ONLY a JSON object: \
        {"type": "specific"|"generic", "terms": [...]}. If the user names a \
        concrete product (brand and product, e.g. "Tallarines San Remo \
        500g"), type is "specific" and terms are 1-3 short ENGLISH words as \
        printed on NZ labels (e.g. ["San Remo", "spaghetti"]). If the user \
        asks for a generic category (e.g. "tallarines", "pasta"), type is \
        "generic" and terms are up to 6 real brand or variant names sold in \
        NZ supermarkets (e.g. San Remo, Vetta, Pams, pasta, spaghetti, \
        noodles). All terms in ENGLISH. JSON only, no explanations.
        """
        let prompt = "City: \(city ?? "New Zealand"). Question: \(query)"
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return parsePlan(from: response.content)
        } catch {
            return nil
        }
    }

    /// Parseo tolerante del JSON del modelo (puro, testeable sin IA).
    static func parsePlan(from text: String) -> QueryPlan? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        let json = String(text[start...end])
        struct DTO: Decodable {
            let type: String
            let terms: [String]
        }
        guard let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let kind = QueryPlan.Kind(rawValue: dto.type)
        else { return nil }
        let terms = dto.terms.compactMap(cleanTerm).prefix(6)
        guard !terms.isEmpty else { return nil }
        return QueryPlan(kind: kind, terms: Array(terms))
    }
}
#endif

/// Agrupa filas reales por EAN y resuelve cada grupo con el mismo camino
/// del escaneo (nearest + cercanas ≤5 km). Descarta filas sin product_name
/// real aunque traigan precio. Ordena por cercanía, tope 5.
func resolveNameRows(
    _ rows: [StorePrice], userLat: Double, userLon: Double, limit: Int = 5
) -> [ScanResult] {
    let valid = rows.filter {
        !$0.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let groups = Dictionary(grouping: valid, by: \.ean)
    let results = groups.compactMap { ean, prices in
        resolveScan(ean: ean, prices: prices, userLat: userLat, userLon: userLon)
    }
    return results
        .sorted { $0.nearestDistanceKm < $1.nearestDistanceKm }
        .prefix(limit)
        .map { $0 }
}
