import Foundation

#if canImport(MWDATCore) && canImport(MWDATDisplay)
import MWDATDisplay

/// Tarjeta de resultado para el Display de los lentes.
/// Misma lógica que el teléfono: a la izquierda el precio más cercano
/// (AQUÍ), a la derecha los competidores cercanos ordenados.
/// Usa solo componentes verificados del sample DisplayAccess.
enum ResultCardView {
    static func card(for result: ScanResult, languageCode: String = Phrasebook.languageCode()) -> FlexBox {
        FlexBox(direction: .row, spacing: 10) {
            FlexBox(direction: .column) {
                Text(L10n.t("here", languageCode), style: .heading)
                Text(
                    "\(result.nearest.effectivePrice) "
                        + "\(result.nearest.currency)",
                    style: .heading
                )
                Text(result.nearest.storeName, style: .body)
                Text(
                    "\(result.nearest.chainName) · "
                        + ShopFormat.distance(km: result.nearestDistanceKm),
                    style: .meta, color: .secondary
                )
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .column, spacing: 6) {
                Text(L10n.t("nearby5km", languageCode), style: .meta, color: .secondary)
                for item in result.nearby.prefix(3) {
                    Text(
                        "\(item.store.storeName): "
                            + "\(item.store.effectivePrice) "
                            + item.store.currency,
                        style: .body
                    )
                }
            }
            .padding(24)
            .background(.card)
        }
    }
}

#endif
