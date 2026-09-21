import Foundation

/// One live reading of the Mac running Hermes.
///
/// CPU is a share of the whole machine, 0–100. A process's CPU is a share of
/// one core, so it can pass 100 on a machine with several cores. Memory is
/// bytes. `warming` means the clock has only just started and the CPU figures
/// are not live yet.
struct HostLoad: Equatable, Sendable {
    struct Process: Identifiable, Equatable, Sendable {
        var id: Int { pid }
        var pid: Int
        var name: String
        /// Percent of one core. Absent until this process has been seen twice.
        var cpu: Double?
        var memory: Int64
        /// session, connection, service, app, helper, or task.
        var effect: String = ""
        /// One line under the name: what stopping it would touch.
        var effectTitle: String = ""
        /// The confirmation, in full.
        var effectDetail: String = ""
        /// The open app, the Mac, or Alice — whatever this process belongs to.
        var affects: String?

        var canStop: Bool {
            effect != "session" && effect != "connection" && pid > 1
        }
    }

    var host: String
    var warming: Bool
    var sampledAt: Date
    /// Percent of the whole Mac.
    var cpuPercent: Double
    var cores: Int
    var load1: Double
    var memoryUsed: Int64
    var memoryTotal: Int64
    /// `ok`, `tight`, or `critical`.
    var memoryPressure: String
    var processes: [Process]

    /// The one sentence the screen leads with.
    func focus(sortedBy sort: HostLoadSort) -> String {
        if memoryPressure == "critical" {
            return "Memory on \(host) is nearly full."
        }
        guard let top = processes.max(by: { lhs, rhs in
            switch sort {
            case .cpu:
                return (lhs.cpu ?? -1) < (rhs.cpu ?? -1)
            case .memory:
                return lhs.memory < rhs.memory
            }
        }) else {
            return warming ? "Measuring \(host)…" : "Nothing is working hard on \(host)."
        }
        switch sort {
        case .cpu:
            guard let cpu = top.cpu, cpu >= 1 else {
                return warming ? "Measuring \(host)…" : "Nothing is working hard on \(host)."
            }
            return "\(top.name) is using the most CPU."
        case .memory:
            return "\(top.name) is using the most memory."
        }
    }

    static func parse(_ object: [String: Any]) -> HostLoad? {
        guard let cpu = object["cpu"] as? [String: Any],
              let memory = object["memory"] as? [String: Any],
              let percent = double(cpu["percent"]),
              let cores = int(cpu["cores"]),
              let used = int64(memory["used"]),
              let total = int64(memory["total"])
        else { return nil }
        let load = cpu["load"] as? [Any]
        let processes = (object["processes"] as? [[String: Any]] ?? []).compactMap(Process.parse)
        return HostLoad(
            host: string(object["host"]) ?? "Mac",
            warming: object["warming"] as? Bool ?? false,
            sampledAt: Date(timeIntervalSince1970: double(object["sampledAt"]) ?? Date().timeIntervalSince1970),
            cpuPercent: percent,
            cores: max(1, cores),
            load1: double(load?.first) ?? 0,
            memoryUsed: used,
            memoryTotal: total,
            memoryPressure: string(memory["pressure"]) ?? "ok",
            processes: processes
        )
    }

    static func bytes(_ count: Int64) -> String {
        let format = ByteCountFormatter()
        format.countStyle = .memory
        format.allowedUnits = count >= 1_000_000_000 ? .useGB : .useMB
        format.includesUnit = true
        format.isAdaptive = false
        return format.string(fromByteCount: count)
    }

    static func percent(_ value: Double, precise: Bool) -> String {
        if precise || value < 10 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.0f%%", value)
    }
}

enum HostLoadSort: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"

    var id: String { rawValue }
}

private extension HostLoad.Process {
    static func parse(_ object: [String: Any]) -> HostLoad.Process? {
        guard let pid = HostLoad.int(object["pid"]),
              let name = HostLoad.string(object["name"]),
              let memory = HostLoad.int64(object["memory"])
        else { return nil }
        return HostLoad.Process(
            pid: pid, name: name, cpu: HostLoad.double(object["cpu"]), memory: memory,
            effect: HostLoad.string(object["effect"]) ?? "",
            effectTitle: HostLoad.string(object["effectTitle"]) ?? "",
            effectDetail: HostLoad.string(object["effectDetail"]) ?? "",
            affects: HostLoad.string(object["affects"])
        )
    }
}

extension HostLoad {
    fileprivate static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    fileprivate static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    fileprivate static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
