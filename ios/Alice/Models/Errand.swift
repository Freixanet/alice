import Foundation

/// A task the person asked for — a purchase, an order, a booking — that runs on its
/// own in Hermes, apart from the chat (`hermes-plugin/errands.py`). Alice shows it as
/// a card and in the list of errands, and nothing is paid until the person approves
/// its checkout here.
struct Errand: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable, CaseIterable {
        case working, needsApproval = "needs_approval", needsInput = "needs_input", needsCard = "needs_card"
        case done, stuck, stopped, denied

        /// Still going, or waiting for the person.
        var isOpen: Bool { self == .working || needsPerson }
        var needsPerson: Bool { self == .needsApproval || self == .needsInput || self == .needsCard }
    }

    struct Item: Hashable, Sendable {
        var name: String
        var variant: String
        var qty: Int
        var price: String
        var image: URL?
    }

    /// The checkout the agent sent before paying, as the shop's page showed it.
    struct Checkout: Hashable, Sendable {
        enum Status: String, Sendable { case pending, approved, denied, expired, replaced }
        let id: String
        var status: Status
        var merchant: String
        var site: String
        var items: [Item]
        var delivery: String
        var address: String
        var email: String
        var cardLabel: String
        var total: String
        var currency: String
    }

    struct Receipt: Hashable, Sendable {
        var outcome: String
        var order: String
        var total: String
        var merchant: String
        var site: String
        var items: [Item]
        var cardLabel: String
        var delivery: String
        var paid: Bool { outcome == "paid" }
    }

    struct Question: Identifiable, Hashable, Sendable {
        let id: String
        var question: String
        var choices: [String]
    }

    /// Another confirmation Hermes asked inside the errand (a login the person wanted to approve).
    struct Approval: Hashable, Sendable {
        var requestID: String
        var title: String
    }

    struct Step: Hashable, Sendable {
        var text: String
        var url: String
        var at: Date
    }

    let id: String
    var title: String
    var request: String
    /// The Hermes session of the chat that asked for it.
    var originSession: String = ""
    /// The payment page's origin a card is wanted for (`needs_card`).
    var cardOrigin: String = ""
    var site: String
    var status: Status
    var checkout: Checkout?
    var receipt: Receipt?
    var questionsTitle: String
    var questions: [Question]
    var approval: Approval?
    var reason: String
    var summary: String
    var steps: [Step]
    var startedAt: Date
    var updatedAt: Date

    var language: ChatLanguage { ChatLanguage.of(request) }
    var lastStep: Step? { steps.last }

    /// Where it is in the purchase, a line per stage rather than per click: the steps grouped by
    /// the page they were on, each group named by what that page is for.
    var milestones: [String] {
        var stages: [String] = []
        var lastPage = ""
        for step in steps {
            let page = Self.page(step.url)
            guard page != lastPage else { continue }
            lastPage = page
            let name = Self.stage(of: step.url, language: language) ?? step.text
            if stages.last != name { stages.append(name) }
        }
        return stages
    }

    private static func page(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        return (parts.host ?? "") + parts.path
    }

    /// What a page of a shop is for, from its address; nil when it says nothing.
    static func stage(of url: String, language: ChatLanguage) -> String? {
        let address = url.lowercased()
        let stages: [([String], String, String)] = [
            (["confirmation", "thank", "gracias", "success", "order-received", "pedido-realizado"],
             "Order confirmation", "Confirmación del pedido"),
            (["payment", "billing", "/pago", "pay?", "redsys", "stripe", "adyen"], "Payment", "Pago"),
            (["shipping", "delivery", "fulfillment", "envio", "entrega", "address"], "Delivery details", "Datos de envío"),
            (["signin", "login", "account/login", "iniciar"], "Signing in", "Inicio de sesión"),
            (["checkout"], "Checkout", "Checkout"),
            (["/bag", "/cart", "carrito", "cesta", "basket"], "Basket", "Cesta"),
            (["search", "buscar", "?q=", "?s="], "Searching", "Buscando"),
        ]
        for (keys, english, spanish) in stages where keys.contains(where: address.contains) {
            return language.pick(english, spanish)
        }
        return nil
    }
    /// How long it has been going, or went.
    var elapsed: TimeInterval { max(0, (status.isOpen ? Date() : updatedAt).timeIntervalSince(startedAt)) }

    static func parse(_ row: [String: Any]) -> Errand? {
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        func date(_ value: Any?) -> Date? {
            (value as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (value as? Int).map { Date(timeIntervalSince1970: Double($0)) }
        }
        func text(_ value: Any?) -> String { (value as? String) ?? "" }
        func items(_ value: Any?) -> [Item] {
            (value as? [[String: Any]] ?? []).compactMap { item in
                let name = text(item["name"])
                guard !name.isEmpty else { return nil }
                let image = text(item["image"])
                return Item(name: name, variant: text(item["variant"]), qty: (item["qty"] as? Int) ?? 1,
                            price: text(item["price"]),
                            image: image.hasPrefix("https://") ? URL(string: image) : nil)
            }
        }
        let checkout = (row["checkout"] as? [String: Any]).flatMap { raw -> Checkout? in
            guard let id = raw["id"] as? String else { return nil }
            return Checkout(
                id: id, status: Checkout.Status(rawValue: text(raw["status"])) ?? .pending,
                merchant: text(raw["merchant"]), site: text(raw["site"]), items: items(raw["items"]),
                delivery: text(raw["delivery"]), address: text(raw["address"]), email: text(raw["email"]),
                cardLabel: text(raw["card_label"]), total: text(raw["total"]), currency: text(raw["currency"]))
        }
        let receipt = (row["receipt"] as? [String: Any]).map { raw in
            Receipt(outcome: text(raw["outcome"]), order: text(raw["order"]), total: text(raw["total"]),
                    merchant: text(raw["merchant"]), site: text(raw["site"]), items: items(raw["items"]),
                    cardLabel: text(raw["card_label"]), delivery: text(raw["delivery"]))
        }
        let asked = row["questions"] as? [String: Any]
        let questions = (asked?["items"] as? [[String: Any]] ?? []).compactMap { raw -> Question? in
            guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
            return Question(id: id, question: question, choices: raw["choices"] as? [String] ?? [])
        }
        let approval = (row["approval"] as? [String: Any]).map {
            Approval(requestID: text($0["request_id"]), title: text($0["title"]))
        }
        let steps = (row["steps"] as? [[String: Any]] ?? []).compactMap { raw -> Step? in
            let words = text(raw["text"])
            guard !words.isEmpty else { return nil }
            return Step(text: words, url: text(raw["url"]), at: date(raw["at"]) ?? Date())
        }
        return Errand(
            id: id, title: title, request: text(row["request"]), originSession: text(row["origin_session"]), cardOrigin: text(row["card_origin"]),
            site: text(row["site"]),
            status: Status(rawValue: text(row["status"])) ?? .working, checkout: checkout, receipt: receipt,
            questionsTitle: text(asked?["title"]), questions: questions, approval: approval,
            reason: text(row["reason"]), summary: text(row["summary"]), steps: steps,
            startedAt: date(row["started_at"]) ?? Date(), updatedAt: date(row["updated_at"]) ?? Date())
    }
}

/// The chat's `errand_start` call: which errand a reply started, for its card.
///
/// The socket's `tool.complete` carries the tool's result (with the errand's id); a
/// transcript read back later has only the arguments, so the title is kept to find it.
struct ErrandRef: Hashable, Sendable {
    static let toolName = "errand_start"

    let errandID: String?
    let title: String

    static func isTool(_ name: String) -> Bool { name == toolName }

    /// The detail `AppStore.toolDetail` keeps for the call: `{"args": …, "result": …}`.
    static func parse(_ detail: String?) -> ErrandRef? {
        guard let data = detail?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let args = object["args"] as? [String: Any] ?? object
        let result = object["result"] as? [String: Any]
        let id = (result?["errand_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = (result?["title"] as? String) ?? (args["title"] as? String) ?? (args["task"] as? String) ?? ""
        guard id != nil || !title.isEmpty else { return nil }
        return ErrandRef(errandID: id, title: title)
    }

    /// The errand this call started: by id when known, else the newest with its title.
    func find(in errands: [Errand]) -> Errand? {
        if let errandID { return errands.first { $0.id == errandID } }
        return errands.filter { $0.title == title }.max { $0.startedAt < $1.startedAt }
    }
}

extension DashboardClient {
    func errands() async throws -> [Errand] {
        let object = try await get("api/plugins/alice/errands")
        return (object["errands"] as? [[String: Any]] ?? []).compactMap(Errand.parse)
    }

    /// «Permitir» or «Denegar» on the checkout the person saw; `checkoutID` pins that exact one.
    func decideCheckout(_ errandID: String, checkoutID: String, allow: Bool, card: String = "") async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/checkout",
                                    ["decision": allow ? "allow" : "deny", "checkout_id": checkoutID, "card_label": card])
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }

    func answerErrand(_ errandID: String, answers: [String: String]) async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/answer", ["answers": answers])
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }

    func approveInErrand(_ errandID: String, requestID: String, allow: Bool) async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/approval",
                                    ["choice": allow ? "once" : "deny", "request_id": requestID])
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }

    /// The shop's own logo, as the plugin found it on the shop's site; nil when it has none.
    func errandIcon(_ errandID: String) async throws -> Data? {
        let (data, response) = try await raw("GET", "api/plugins/alice/errands/\(errandID)/icon")
        guard response.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    func errandCardReady(_ errandID: String, label: String) async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/card", ["label": label])
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }

    /// A stale checkout, prepared again by the errand for a new approval.
    func refreshCheckout(_ errandID: String) async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/refresh")
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }

    func stopErrand(_ errandID: String) async throws -> Errand? {
        let object = try await send("POST", "api/plugins/alice/errands/\(errandID)/stop")
        return (object["errand"] as? [String: Any]).flatMap(Errand.parse)
    }
}
