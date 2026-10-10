import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let path = CommandLine.arguments[1]
let samples = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
func encode(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}
for sample in samples {
    guard case .calculator = UIComponent(json: encode(sample)) else { fatalError("actual chat component dispatch failed") }
}
let skill = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let nativeExample = skill.components(separatedBy: "```alice-ui\n")[1].components(separatedBy: "\n```")[0]
require(NativeCalculator(json: nativeExample) != nil, "actual agent guide example validates")
let calculators = samples.map { NativeCalculator(json: encode($0))! }
require(calculators.count == 3, "all real gallery samples validate")
let budget = calculators[0]
require(budget.evaluate(budget.initialValues) == [1000, 12000], "budget initial result")
var values = budget.initialValues
values["leisure"] = 700
require(budget.evaluate(values) == [500, 6000], "edits recompute all results locally")
values["income"] = 0
require(budget.evaluate(values) == [-2000, -24000], "negative results preserved")
values["leisure"] = 1201
require(budget.evaluate(values) == nil, "out of range clears stale output")
values = budget.initialValues; values.removeValue(forKey: "income")
require(budget.evaluate(values) == nil, "empty field clears stale output")
values = budget.initialValues; values["income"] = .nan
require(budget.evaluate(values) == nil, "non-finite input rejected")
let comparison = calculators[1]
require(comparison.evaluate(comparison.initialValues) == [184, 216, 32], "comparison identity and totals")
var months = comparison.initialValues; months["months"] = 1
require(comparison.evaluate(months) == [52, 18, -34], "comparison tradeoff reverses")
let bill = calculators[2]
require(bill.evaluate(bill.initialValues) == [28, 84], "bill division")
var split = bill.initialValues; split["tip"] = 10
require(abs(bill.evaluate(split)![0] - 30.8) < 0.000001, "fractional bill result")
split["people"] = 1.5
require(bill.evaluate(split) == nil, "discrete sliders refuse fractional edits")
split["people"] = 0
require(bill.evaluate(split) == nil, "zero people blocked")
for text in ["", "NaN", "inf", "20abc", "1.2.3", "1e9", "1,200.00"] {
    require(NativeCalculator.parseInput(text, locale: Locale(identifier: "en_US")) == nil, "no partial parsing: \(text)")
}
require(NativeCalculator.parseInput("12,50", locale: Locale(identifier: "es_ES")) == 12.5, "Spanish decimal keyboard")
require(NativeCalculator.parseInput("-0.25", locale: Locale(identifier: "en_US")) == -0.25, "negative decimal")
for value in [0.0, 0.125, 1e-20, 1e12, -12.75] {
    let locale = Locale(identifier: "es_ES")
    let roundtrip = NativeCalculator.parseInput(NativeCalculator.formatInput(value, locale: locale), locale: locale)
    require(roundtrip == value, "initial/edit formatting must preserve numeric value: \(value)")
}
var bad = samples[0]; bad["execute"] = "pay"
require(NativeCalculator(json: encode(bad)) == nil, "unknown capabilities rejected")
var rows = samples[0]["inputs"] as! [[String: Any]]
rows[0]["value"] = true; bad = samples[0]; bad["inputs"] = rows
require(NativeCalculator(json: encode(bad)) == nil, "boolean is not a number")
rows = samples[0]["inputs"] as! [[String: Any]]; rows[1]["id"] = rows[0]["id"]
bad = samples[0]; bad["inputs"] = rows
require(NativeCalculator(json: encode(bad)) == nil, "duplicate IDs rejected")
for tokens in [["income", "+"], ["income", "fixed"], ["payment()"], ["income", "0", "/"], ["1e12", "1e12", "*"]] {
    bad = samples[0]
    var outputs = bad["outputs"] as! [[String: Any]]; outputs[0]["expression"] = tokens; bad["outputs"] = outputs
    require(NativeCalculator(json: encode(bad)) == nil, "malformed/unsafe/undefined arithmetic rejected")
}
bad = samples[0]; var outputs = bad["outputs"] as! [[String: Any]]
outputs[0]["expression"] = ["income", "leisure", "/"]; bad["outputs"] = outputs
let divisor = NativeCalculator(json: encode(bad))!
var divided = divisor.initialValues; divided["leisure"] = 0
require(divisor.evaluate(divided) == nil, "valid initial formula later divides by zero: clear results")
for op in ["min", "max"] {
    bad = samples[0]; outputs = bad["outputs"] as! [[String: Any]]
    outputs[0]["expression"] = ["income", "fixed", op]; bad["outputs"] = outputs
    let model = NativeCalculator(json: encode(bad))!
    require(model.evaluate(model.initialValues)![0] == (op == "min" ? 1300 : 2500), "bounded \(op)")
}
print("Native calculators: gallery, edits, comparisons, decimals and rejection paths passed. No model calls.")
