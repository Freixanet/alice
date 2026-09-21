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

    private func parse(_ json: String) throws -> HostLoad {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(HostLoad.parse(object))
    }

    func testAnOlderPluginStillShowsEachProcessAsItsOwnRow() throws {
        let load = try parse(#"""
        {"host":"studio","warming":false,"sampledAt":1,
         "cpu":{"percent":10,"cores":8,"load":[1,1,1]},
         "memory":{"used":1,"total":2,"pressure":"ok"},
         "processes":[{"pid":42,"name":"Safari","cpu":3,"memory":500,"effect":"app"},
                      {"pid":1,"name":"launchd","cpu":0,"memory":10,"effect":"session"}]}
        """#)
        XCTAssertEqual(load.groups.map(\.name), ["Safari", "launchd"])
        XCTAssertEqual(load.groups.first?.stopPid, 42)
        XCTAssertFalse(load.groups[1].canStop)
    }

    func testASwappingMacSaysSoAndOffersTheAppThatFreesTheMost() throws {
        let load = try parse(#"""
        {"host":"studio","warming":false,"sampledAt":1,
         "cpu":{"percent":10,"cores":8,"load":[7,7,7]},
         "memory":{"used":8,"total":16,"pressure":"tight","swapUsed":8000000000,
                   "swapTotal":9000000000,"swapInRate":6000000},
         "processes":[],
         "groups":[
          {"id":"app:/Applications/Aside","name":"Aside","cpu":4,"memory":1700000000,"count":35,
           "stopPid":10,"stopName":"Aside","effect":"app"},
          {"id":"hermes","name":"Hermes","cpu":13,"memory":2900000000,"count":10,"effect":"hermes"},
          {"id":"app:/Applications/Notes","name":"Notes","cpu":0,"memory":200000000,"count":1,
           "stopPid":11,"stopName":"Notes","effect":"app"}]}
        """#)
        XCTAssertTrue(load.isSwapping)
        let verdict = load.verdict()
        XCTAssertEqual(verdict.headline, "studio is short of memory.")
        // Hermes is larger but is never offered: it runs the agents.
        XCTAssertEqual(verdict.remedy?.name, "Aside")
        XCTAssertFalse(load.groups[1].canStop)
    }

    func testACalmMacSaysWhatHoldsTheMostMemory() throws {
        let load = try parse(#"""
        {"host":"studio","warming":false,"sampledAt":1,
         "cpu":{"percent":5,"cores":8,"load":[1,1,1]},
         "memory":{"used":4,"total":16,"pressure":"ok"},
         "processes":[],
         "groups":[{"id":"app:/Applications/Cursor","name":"Cursor","cpu":1,"memory":1200000000,"count":12,"stopPid":3,"effect":"app"}]}
        """#)
        let verdict = load.verdict()
        XCTAssertEqual(verdict.headline, "studio is running smoothly.")
        XCTAssertNil(verdict.remedy)
        XCTAssertTrue(verdict.detail?.hasPrefix("Cursor holds the most memory") == true)
    }
}

