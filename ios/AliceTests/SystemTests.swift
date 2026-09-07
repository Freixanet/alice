import XCTest
@testable import Alice

final class SystemTests: XCTestCase {
    func testSystemStatusPreservesComponentHealthAndPressure() throws {
        let status = try DashboardClient.systemStatus(from: [
            "version": "0.21.0",
            "release_date": "2026.8.31",
            "overall": "degraded",
            "gateway_running": true,
            "gateway_state": "running",
            "active_sessions": 2,
            "active_agents": 1,
            "gateway_busy": true,
            "gateway_drainable": true,
            "profiles": ["default", "radar-ia"],
            "gateway_mode": "multiple",
            "memory": ["pressure": "elevated"],
            "disk": ["pressure": "critical", "used_percent": 98.2],
            "components": [
                "gateway": ["status": "ok", "state": "running"],
                "platforms": ["status": "degraded", "configured": 3, "connected": 2],
            ],
        ])

        XCTAssertEqual(status.overall, "degraded")
        XCTAssertTrue(status.gatewayRunning)
        XCTAssertTrue(status.gatewayBusy)
        XCTAssertEqual(status.profiles, ["default", "radar-ia"])
        XCTAssertEqual(status.memoryPressure, "elevated")
        XCTAssertEqual(status.diskPressure, "critical")
        XCTAssertEqual(status.diskUsedPercent, 98.2)
        XCTAssertEqual(status.components.first(where: { $0.name == "platforms" })?.connected, 2)
    }

    func testMalformedSystemStatusDoesNotBecomeStoppedHermes() {
        XCTAssertThrowsError(try DashboardClient.systemStatus(from: ["version": "0.21.0"]))
    }

    func testSystemStatsKeepHostResources() throws {
        let stats = try DashboardClient.systemStats(from: [
            "os": "Darwin", "os_release": "25.6.0", "platform": "macOS",
            "arch": "x86_64", "hostname": "Hermes-Mac", "hermes_version": "0.21.0",
            "python_version": "3.11.11", "python_impl": "CPython", "cpu_count": 16,
            "cpu_percent": 21.5, "load_avg": [1.0, 2.0, 3.0], "uptime_seconds": 90061,
            "psutil": true,
            "memory": ["total": 16_000, "used": 8_000, "available": 8_000, "percent": 50.0],
            "disk": ["total": 100_000, "used": 90_000, "free": 10_000, "percent": 90.0],
        ])

        XCTAssertEqual(stats.cpuCount, 16)
        XCTAssertEqual(stats.loadAverage, [1, 2, 3])
        XCTAssertEqual(stats.memory?.percent, 50)
        XCTAssertEqual(stats.memory?.free, 8_000)
        XCTAssertEqual(stats.disk?.free, 10_000)
        XCTAssertEqual(stats.uptimeSeconds, 90061)
    }

    func testActionStatusKeepsLiveOutputAndExitCode() throws {
        let status = try DashboardClient.actionStatus(from: [
            "name": "doctor", "running": false, "exit_code": 0,
            "pid": 42, "lines": ["checking", "done"],
        ])
        XCTAssertEqual(status.name, "doctor")
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(status.lines, ["checking", "done"])
    }

    func testCheckpointParserPreservesBytesPerSession() throws {
        let snapshot = try DashboardClient.checkpoints(from: [
            "sessions": [
                ["session": "abc", "files": 3, "bytes": 4096],
                ["session": "def", "files": 1, "bytes": 1024],
            ],
            "total_bytes": 5120,
        ])
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.sessions[0].files, 3)
        XCTAssertEqual(snapshot.totalBytes, 5120)
    }

    func testLogParserRequiresRealLinesCollection() throws {
        let log = try DashboardClient.logSnapshot(from: [
            "file": "gateway", "lines": ["one\n", "two\n"],
        ])
        XCTAssertEqual(log.file, "gateway")
        XCTAssertEqual(log.lines.count, 2)
        XCTAssertThrowsError(try DashboardClient.logSnapshot(from: ["file": "gateway"]))
    }
}
