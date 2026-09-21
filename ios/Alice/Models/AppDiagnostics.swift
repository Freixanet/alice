import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What Alice tells Hermes about this phone: connection, build and the
/// recent diagnostics log. Never a message, a key or an address.
struct AppDiagnosticsSnapshot: Equatable, Sendable {
    var deviceID: String
    var capturedAt: Date
    var version: String
    var build: String
    var revision: String?
    var wellbeing: String
    var connected: Bool
    var dashboardReady: Bool
    var gatewayConfigured: Bool
    var unknownEvents: [String]
    var lines: [String]

    @MainActor
    static var vendorDeviceID: String {
        #if canImport(UIKit)
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #else
        "unknown"
        #endif
    }

    /// JSON for `POST api/plugins/alice/app/diagnostics`.
    func jsonObject() -> [String: Any] {
        var body: [String: Any] = [
            "device_id": deviceID,
            "captured_at": capturedAt.ISO8601Format(.iso8601(timeZone: .current)),
            "version": version,
            "build": build,
            "wellbeing": wellbeing,
            "connected": connected,
            "dashboard_ready": dashboardReady,
            "gateway_configured": gatewayConfigured,
            "unknown_events": unknownEvents,
            "lines": lines,
        ]
        if let revision { body["revision"] = revision }
        return body
    }

    /// What `/debug` puts in the current chat.
    func chatSummary(uploaded: Bool) -> String {
        var parts: [String] = [
            "**Alice diagnostics**",
            "",
            "Version \(version) (\(build))" + (revision.map { " · \($0)" } ?? ""),
            "Hermes: \(wellbeing)",
            "Gateway configured: \(gatewayConfigured ? "yes" : "no")",
            "Connected: \(connected ? "yes" : "no")",
            "Dashboard ready: \(dashboardReady ? "yes" : "no")",
        ]
        if unknownEvents.isEmpty {
            parts.append("Unknown events: none")
        } else {
            parts.append("Unknown events:")
            parts.append(contentsOf: unknownEvents.prefix(8).map { "- \($0)" })
        }
        let errors = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("fail") || lower.contains("error")
                || lower.contains("timeout") || lower.contains("losttouch")
                || lower.contains("reconnecting") || lower.contains("endedunseen")
        }
        if errors.isEmpty {
            parts.append("Recent errors: none in the last \(lines.count) log lines")
        } else {
            parts.append("Recent errors:")
            parts.append(contentsOf: errors.suffix(12).map { "- \($0)" })
        }
        parts.append("")
        parts.append(
            uploaded
                ? "Copied to Hermes. Ask Alice what is going wrong and she can read this dump."
                : "Could not reach the Alice plugin; this copy is only on the phone."
        )
        return parts.joined(separator: "\n")
    }
}
