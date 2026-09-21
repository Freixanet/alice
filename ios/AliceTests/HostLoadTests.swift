import XCTest
@testable import Alice

final class HostLoadTests: XCTestCase {
    func testALiveReadingParses() throws {
        let data = Data(#"""
        {"host":"studio","warming":false,"sampledAt":1700000000,
         "cpu":{"percent":22.5,"cores":8,"load":[1.25,1,0.8]},
         "memory":{"used":8000000000,"total":16000000000,"pressure":"ok"},
         "processes":[{"pid":42,"name":"Safari","cpu":30.2,"memory":500000000,"effect":"app","effectTitle":"Open app · closes Safari","effectDetail":"Unsaved work in Safari can be lost.","affects":"Safari"}]}
        """#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let load = try XCTUnwrap(HostLoad.parse(object))
        XCTAssertEqual(load.host, "studio")
        XCTAssertEqual(load.cpuPercent, 22.5)
        XCTAssertEqual(load.cores, 8)
        XCTAssertEqual(load.load1, 1.25)
        XCTAssertEqual(load.memoryUsed, 8_000_000_000)
        XCTAssertEqual(load.processes.first?.name, "Safari")
        XCTAssertEqual(load.processes.first?.effect, "app")
        XCTAssertEqual(load.processes.first?.affects, "Safari")
        XCTAssertEqual(load.processes.first?.cpu, 30.2)
        XCTAssertEqual(load.focus(sortedBy: .cpu), "Safari is using the most CPU.")
    }

    func testAFirstReadingDoesNotInventCPU() throws {
        let data = Data(#"""
        {"host":"studio","warming":true,"sampledAt":1,
         "cpu":{"percent":0,"cores":8,"load":[0,0,0]},
         "memory":{"used":1,"total":2,"pressure":"ok"},
         "processes":[{"pid":1,"name":"kernel_task","cpu":null,"memory":10}]}
        """#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let load = try XCTUnwrap(HostLoad.parse(object))
        XCTAssertTrue(load.warming)
        XCTAssertNil(load.processes.first?.cpu)
        XCTAssertEqual(load.focus(sortedBy: .cpu), "Measuring studio…")
    }

    func testAFullMacSaysSo() throws {
        let data = Data(#"""
        {"host":"studio","warming":false,"sampledAt":1,
         "cpu":{"percent":10,"cores":8,"load":[1,1,1]},
         "memory":{"used":15,"total":16,"pressure":"critical"},
         "processes":[{"pid":1,"name":"Safari","cpu":4,"memory":10}]}
        """#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let load = try XCTUnwrap(HostLoad.parse(object))
        XCTAssertEqual(load.focus(sortedBy: .cpu), "Memory on studio is nearly full.")
    }
}
