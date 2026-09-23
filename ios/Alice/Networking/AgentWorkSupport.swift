import Foundation

/// The agents' shared browser as the Alice plugin reports it (`browser_live.py`).
struct SharedBrowserState: Equatable, Sendable {
    /// Alice turned it on and keeps it running.
    var managed = false
    /// Some browser is set for the agents, Alice's or one of the person's own.
    var configured = false
    /// That browser is on the Mac, so the phone can reach it.
    var local = false
    var running = false
    /// A Chromium-family browser exists on the Mac to start one with.
    var available = false
    var pageTitle: String?
    var pageURL: String?

    /// The phone can open the live view right now.
    var watchable: Bool { configured && local && running }

    static func parse(_ object: [String: Any]) -> SharedBrowserState {
        let page = object["page"] as? [String: Any]
        return SharedBrowserState(
            managed: object["managed"] as? Bool ?? false,
            configured: object["configured"] as? Bool ?? false,
            local: object["local"] as? Bool ?? false,
            running: object["running"] as? Bool ?? false,
            available: object["available"] as? Bool ?? false,
            pageTitle: (page?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            pageURL: (page?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// One picture of the page and where it is.
struct SharedBrowserFrame: Sendable {
    let seq: Int
    let jpeg: Data?
    /// The page's size in CSS pixels, for mapping a tap.
    let width: Double?
    let height: Double?
    let url: String
    let title: String
    let target: String
}

/// Something the person does to the page.
enum SharedBrowserAction: Sendable {
    case tap(x: Double, y: Double)
    case scroll(x: Double, y: Double, dy: Double)
    case text(String)
    case key(String)
    case navigate(String)
    case back, forward, reload

    var body: [String: Any] {
        switch self {
        case let .tap(x, y): ["kind": "tap", "x": x, "y": y]
        case let .scroll(x, y, dy): ["kind": "scroll", "x": x, "y": y, "dy": dy]
        case let .text(text): ["kind": "text", "text": text]
        case let .key(key): ["kind": "key", "key": key]
        case let .navigate(url): ["kind": "navigate", "url": url]
        case .back: ["kind": "back"]
        case .forward: ["kind": "forward"]
        case .reload: ["kind": "reload"]
        }
    }
}

/// A page watched for the person (`page_watch.py`).
struct PageWatch: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case price, stock, change, text
    }

    let id: String
    let kind: Kind
    let url: String
    let label: String
    let below: Double?
    let text: String?
    let price: Double?
    let currency: String?
    let inStock: Bool?
    let lastChecked: Date?
    let lastChanged: Date?
    let error: String?

    static func parse(_ row: [String: Any]) -> PageWatch? {
        guard let id = row["id"] as? String, let url = row["url"] as? String,
              let kind = (row["kind"] as? String).flatMap(Kind.init(rawValue:))
        else { return nil }
        func number(_ key: String) -> Double? {
            (row[key] as? Double) ?? (row[key] as? Int).map(Double.init) ?? (row[key] as? String).flatMap(Double.init)
        }
        func date(_ key: String) -> Date? { number(key).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        let error = row["error"].flatMap { value -> String? in
            if let text = value as? String, !text.isEmpty { return text }
            return nil
        }
        return PageWatch(
            id: id, kind: kind, url: url, label: (row["label"] as? String) ?? url,
            below: number("below"), text: row["text"] as? String,
            price: number("price"), currency: row["currency"] as? String,
            inStock: row["in_stock"] as? Bool,
            lastChecked: date("last_checked"), lastChanged: date("last_changed"), error: error
        )
    }
}

struct PageWatchService: Equatable, Sendable {
    var installed = false
    var running = false
    var installing = false
    var failed: String?

    static func parse(_ object: [String: Any]) -> PageWatchService {
        PageWatchService(
            installed: object["installed"] as? Bool ?? false,
            running: object["running"] as? Bool ?? false,
            installing: object["installing"] as? Bool ?? false,
            failed: (object["failed"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

extension DashboardClient {
    // MARK: Shared browser

    func sharedBrowser() async throws -> SharedBrowserState {
        SharedBrowserState.parse(try await get("api/plugins/alice/browser"))
    }

    func setSharedBrowser(on: Bool) async throws -> SharedBrowserState {
        SharedBrowserState.parse(try await send("POST", "api/plugins/alice/browser/\(on ? "enable" : "disable")", [:]))
    }

    /// The newest frame, waiting up to a second and a half for one after `after`.
    func sharedBrowserFrame(after: Int, target: String?) async throws -> SharedBrowserFrame {
        var path = "api/plugins/alice/browser/frame?after=\(after)"
        if let target, !target.isEmpty { path += "&target=\(target)" }
        let (data, response) = try await raw("GET", path)
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        return SharedBrowserFrame(
            seq: header("X-Alice-Seq").flatMap(Int.init) ?? after,
            jpeg: response.statusCode == 204 || data.isEmpty ? nil : data,
            width: header("X-Alice-Width").flatMap(Double.init),
            height: header("X-Alice-Height").flatMap(Double.init),
            url: header("X-Alice-Url")?.removingPercentEncoding ?? "",
            title: header("X-Alice-Title")?.removingPercentEncoding ?? "",
            target: header("X-Alice-Target") ?? ""
        )
    }

    func sharedBrowserInput(_ action: SharedBrowserAction, target: String?) async throws {
        var body = action.body
        if let target, !target.isEmpty { body["target"] = target }
        _ = try await send("POST", "api/plugins/alice/browser/input", body)
    }

    // MARK: Page watches

    func pageWatches() async throws -> (service: PageWatchService, watches: [PageWatch]) {
        let object = try await get("api/plugins/alice/watches")
        let service = PageWatchService.parse(object["status"] as? [String: Any] ?? [:])
        let rows = (object["watches"] as? [[String: Any]]) ?? []
        return (service, rows.compactMap(PageWatch.parse))
    }

    func setUpPageWatches() async throws -> PageWatchService {
        let object = try await send("POST", "api/plugins/alice/watches/setup", [:])
        return PageWatchService.parse(object["status"] as? [String: Any] ?? [:])
    }

    func createPageWatch(url: String, kind: PageWatch.Kind, label: String, below: Double?, text: String) async throws {
        var body: [String: Any] = ["url": url, "kind": kind.rawValue, "label": label, "text": text]
        if let below { body["below"] = below }
        _ = try await send("POST", "api/plugins/alice/watches", body)
    }

    func deletePageWatch(_ id: String) async throws {
        _ = try await send("DELETE", "api/plugins/alice/watches/\(id)")
    }

    // MARK: Documents

    /// A document from the phone, kept on the Mac where agents' tools open it.
    /// Returns its absolute path there.
    func uploadDocument(name: String, data: Data) async throws -> String {
        let object = try await send("POST", "api/plugins/alice/files", [
            "name": name, "data": data.base64EncodedString(),
        ])
        guard let path = object["path"] as? String else { throw Failure.unreadable }
        return path
    }
}

extension DashboardClient.Failure {
    /// The plugin's own sentence, when it gave one, instead of "returned 409".
    var plainWords: String {
        if case let .http(_, detail) = self, let detail, !detail.isEmpty { return detail }
        return errorDescription ?? String(describing: self)
    }
}
