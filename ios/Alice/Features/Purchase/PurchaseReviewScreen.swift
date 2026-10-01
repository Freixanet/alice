#if DEBUG
import SwiftUI

/// Isolated native fixtures for CI screenshots; this mode has no purchase transport.
struct PurchaseReviewScreen: View {
    @Environment(AppStore.self) private var store
    @State private var selection = ""
    private var options: PurchaseOptionSet {
        PurchaseOptionSet(key: "aabbccdd", options: (0..<8).map { i in
            let variant = ["300 g", "80 cápsulas", "90 cápsulas", "500 g", "1 kg", "120 cápsulas", "250 g", "2 kg"][i]
            return PurchaseOption(id: "aabbccdd-\(i+1)", title: "Creapure \(variant)", merchant: "Prozis",
                                  variant: variant, qty: 1, price: "34,99 €", image: nil, url: nil,
                                  recommended: i == 0, why: i == 0 ? "Formato en polvo disponible" : "",
                                  shipping: "3,99 €", condition: "24,49 € requiere suscripción; no aplicado.")
        }, chosen: nil)
    }
    private var pending: Errand {
        Errand.parse(["id": "fixture-errand", "title": "Comprar Creapure", "request": "Compra la creatina de Prozis",
                      "status": "needs_login", "site": "example.com",
                      "secure_request": ["request_id": "srq-fixture", "kind": "vault.save_login", "origin": "https://example.com", "site": "Tienda de prueba"]])!
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Opciones comprobadas").font(.headline)
                PurchaseOptionsCard(detail: nil, language: .spanish, preview: options,
                                    onChooseQuantity: { option, qty in selection = "\(option.variant) · \(qty) unidades" })
                Text(selection).accessibilityIdentifier("purchase.selection")
                ErrandStack(errand: pending, onOpenBrowser: {}, onDecide: { _,_ in }, onAnswer: { _ in }, onConfirm: { _ in })
            }.padding()
        }
        .sheet(item: Bindable(store).secureRequest) { request in SecureRequestSheet(request: request) }
    }
}
#endif
