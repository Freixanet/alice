import Foundation

@main
struct CheckDrawerSettlement {
    static func main() {
        let cases: [(String, Bool, CGFloat, CGFloat, Bool)] = [
            ("short opening returns", false, 40, 40, false),
            ("distance opening", false, 100, 100, true),
            ("fast short opening", false, 20, 160, true),
            ("reverse opening flick", false, 60, -160, false),
            ("reverse long opening flick", false, 180, -20, false),
            ("return beyond origin", false, -10, -20, false),
            ("opening projected to origin", false, 100, 0, false),
            ("short closing returns", true, -40, -40, true),
            ("distance closing", true, -100, -100, false),
            ("fast short closing", true, -20, -160, false),
            ("reverse closing flick", true, -60, 160, true),
            ("reverse long closing flick", true, -180, 20, true),
            ("closing projected to origin", true, -100, 0, true),
            ("opening distance boundary", false, 90, 90, false),
            ("closing distance boundary", true, -90, -90, true),
            ("opening projection boundary", false, 20, 120, false),
            ("closing projection boundary", true, -20, -120, true),
        ]
        for (name, wasOpen, translation, predicted, expected) in cases {
            precondition(DrawerSettlement.isOpen(
                wasOpen: wasOpen, translation: translation, predicted: predicted, width: 300
            ) == expected, name)
        }
        print("PASS: \(cases.count) drawer settlement scenarios")
    }
}
