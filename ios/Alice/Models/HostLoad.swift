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
            effect != "session" && effect != "connection" && effect != "hermes" && pid > 1
        }
    }

    /// One app — or one command — with every process it runs. A browser's
    /// forty helpers are the browser.
    struct Group: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        /// Percent of one core, summed over its processes.
        var cpu: Double?
        var memory: Int64
        var count: Int
        /// The process that closes the whole app, when there is one to close.
        var stopPid: Int?
        var stopName: String?
        var effect: String = ""
        var effectTitle: String = ""
        var effectDetail: String = ""
        var affects: String?
        var members: [Process] = []

        var canStop: Bool {
            stopPid != nil && effect != "session" && effect != "connection" && effect != "hermes"
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
    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0
    /// Bytes a second read back from swap: the Mac waiting on its disk.
    var swapInRate: Int64 = 0
    /// Apps, from the Mac when its plugin groups them; otherwise one per process.
    var groups: [Group] = []

    /// Reading back from swap at this rate is felt as slowness.
    static let swappingRate: Int64 = 1024 * 1024

    var isSwapping: Bool { swapInRate >= Self.swappingRate }

    /// What the screen leads with: what is going on, why, and — when there
    /// is one — the app whose closing would help most.
    struct Verdict: Equatable {
        var headline: String
        var detail: String?
        var remedy: Group?
    }

    func verdict() -> Verdict {
        if warming { return Verdict(headline: "Measuring \(host)…") }
        let freeing = groups
            .filter { $0.canStop && $0.effect == "app" && $0.memory >= 300 * 1024 * 1024 }
            .max { $0.memory < $1.memory }
        if isSwapping {
            return Verdict(
                headline: "\(host) is short of memory.",
                detail: "It is reading \(Self.bytes(swapInRate))/s back from its disk, which is what makes it slow.",
                remedy: freeing
            )
        }
        if memoryPressure == "critical" {
            return Verdict(headline: "Memory on \(host) is nearly full.", detail: nil, remedy: freeing)
        }
        let busiest = groups.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }
        if cpuPercent >= 75, let busiest, (busiest.cpu ?? 0) >= 50 {
            return Verdict(
                headline: "\(busiest.name) is working \(host) hardest.",
                detail: "\(Self.percent(cpuPercent, precise: false)) of the whole Mac is busy.",
                remedy: nil
            )
        }
        if memoryPressure == "tight" {
            return Verdict(headline: "Memory on \(host) is getting tight.", detail: nil, remedy: freeing)
        }
        let largest = groups.max { $0.memory < $1.memory }
        return Verdict(
            headline: "\(host) is running smoothly.",
            detail: largest.map { "\($0.name) holds the most memory, \(Self.bytes($0.memory))." },
            remedy: nil
        )
    }

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
        var groups = (object["groups"] as? [[String: Any]] ?? []).compactMap(Group.parse)
        if groups.isEmpty {
            // A plugin from before apps were grouped: each process stands alone.
            groups = processes.map { process in
                Group(
                    id: "pid:\(process.pid)", name: process.name, cpu: process.cpu,
                    memory: process.memory, count: 1,
                    stopPid: process.canStop ? process.pid : nil,
                    stopName: process.canStop ? process.name : nil,
                    effect: process.effect, effectTitle: process.effectTitle,
                    effectDetail: process.effectDetail, affects: process.affects,
                    members: [process]
                )
            }
        }
        var reading = HostLoad(
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
        reading.swapUsed = int64(memory["swapUsed"]) ?? 0
        reading.swapTotal = int64(memory["swapTotal"]) ?? 0
        reading.swapInRate = int64(memory["swapInRate"]) ?? 0
        reading.groups = groups
        return reading
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

private extension HostLoad.Group {
    static func parse(_ object: [String: Any]) -> HostLoad.Group? {
        guard let id = HostLoad.string(object["id"]),
              let name = HostLoad.string(object["name"]),
              let memory = HostLoad.int64(object["memory"])
        else { return nil }
        return HostLoad.Group(
            id: id, name: name, cpu: HostLoad.double(object["cpu"]), memory: memory,
            count: HostLoad.int(object["count"]) ?? 1,
            stopPid: HostLoad.int(object["stopPid"]),
            stopName: HostLoad.string(object["stopName"]),
            effect: HostLoad.string(object["effect"]) ?? "",
            effectTitle: HostLoad.string(object["effectTitle"]) ?? "",
            effectDetail: HostLoad.string(object["effectDetail"]) ?? "",
            affects: HostLoad.string(object["affects"]),
            members: (object["members"] as? [[String: Any]] ?? []).compactMap(HostLoad.Process.parse)
        )
    }
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
