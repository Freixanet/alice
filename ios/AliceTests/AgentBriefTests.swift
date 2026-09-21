import XCTest
@testable import Alice

final class AgentBriefTests: XCTestCase {
    func testThereAreEightTemplates() {
        XCTAssertEqual(AgentBrief.templates.count, 8)
    }

    func testTemplateIdsAreUnique() {
        let ids = AgentBrief.templates.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTitlesMatchTheEightRoles() {
        XCTAssertEqual(
            AgentBrief.templates.map(\.title),
            [
                "Inbox",
                "Personal assistant",
                "News watcher",
                "Deal hunter",
                "Tutor",
                "Writer",
                "Researcher",
                "Reminders",
            ]
        )
    }

    func testEachBriefIsShortEnoughToShowOnAPhone() {
        for template in AgentBrief.templates {
            XCTAssertFalse(template.brief.isEmpty, template.id)
            XCTAssertLessThan(template.brief.count, 300, template.id)
        }
    }

    func testEachSoulExtraIsShortAndCarriesTheCostRules() {
        for template in AgentBrief.templates {
            XCTAssertFalse(template.soulExtra.isEmpty, template.id)
            XCTAssertLessThan(template.soulExtra.count, 500, template.id)
            for rule in AgentBrief.costRules {
                XCTAssertTrue(template.soulExtra.contains(rule), "\(template.id) missing \(rule)")
            }
        }
    }

    func testEachTemplateHasASymbolAndAName() {
        for template in AgentBrief.templates {
            XCTAssertFalse(template.symbol.isEmpty, template.id)
            XCTAssertFalse(template.name.isEmpty, template.id)
        }
    }
}
