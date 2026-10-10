import Foundation
import CoreFoundation

/// Bounded arithmetic, never generated Swift/JavaScript or external actions.
struct NativeCalculator: Hashable, Sendable {
    struct Input: Hashable, Sendable, Identifiable {
        let id: String
        let label: String
        let value: Double
        let min: Double
        let max: Double
        let step: Double
        let control: String
        let unit: String
    }
    struct Output: Hashable, Sendable, Identifiable {
        let id: String
        let label: String
        let expression: [String]
        let unit: String
    }
    let title: String
    let summary: String
    let inputs: [Input]
    let outputs: [Output]
    static let operators: Set<String> = ["+", "-", "*", "/", "min", "max"]
    var initialValues: [String: Double] { Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.value) }) }

    init?(json: String) {
        guard json.utf8.count <= 32_000, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["type", "title", "summary", "inputs", "outputs"],
              root["type"] as? String == "calculator",
              let title = Self.text(root["title"], limit: 160),
              let summary = Self.text(root["summary"], limit: 2000),
              let rows = root["inputs"] as? [[String: Any]], (1...12).contains(rows.count),
              let results = root["outputs"] as? [[String: Any]], (1...8).contains(results.count)
        else { return nil }
        var inputs: [Input] = []
        for row in rows {
            guard Set(row.keys) == ["id", "label", "value", "min", "max", "step", "control", "unit"],
                  let id = Self.identifier(row["id"]), let label = Self.text(row["label"], limit: 100),
                  let value = Self.number(row["value"]), let lower = Self.number(row["min"]),
                  let upper = Self.number(row["max"]), let step = Self.number(row["step"]),
                  lower < upper, upper - lower <= 1e9, step > 0, step <= upper - lower,
                  (lower...upper).contains(value),
                  let control = row["control"] as? String, ["field", "slider"].contains(control),
                  let unit = Self.unit(row["unit"])
            else { return nil }
            inputs.append(Input(id: id, label: label, value: value, min: lower, max: upper,
                                step: step, control: control, unit: unit))
        }
        guard Set(inputs.map(\.id)).count == inputs.count else { return nil }
        let ids = Set(inputs.map(\.id))
        var outputs: [Output] = []
        for row in results {
            guard Set(row.keys) == ["id", "label", "expression", "unit"],
                  let id = Self.identifier(row["id"]), let label = Self.text(row["label"], limit: 100),
                  let unit = Self.unit(row["unit"]), let expression = row["expression"] as? [String],
                  (1...32).contains(expression.count)
            else { return nil }
            var depth = 0
            for token in expression {
                if Self.operators.contains(token) {
                    guard depth >= 2 else { return nil }; depth -= 1
                } else {
                    guard ids.contains(token) || Self.constant(token) != nil else { return nil }; depth += 1
                }
            }
            guard depth == 1 else { return nil }
            outputs.append(Output(id: id, label: label, expression: expression, unit: unit))
        }
        guard Set(outputs.map(\.id)).count == outputs.count else { return nil }
        self.title = title; self.summary = summary; self.inputs = inputs; self.outputs = outputs
        guard evaluate(initialValues) != nil else { return nil }
    }

    /// Missing/invalid input or a zero divisor clears every result, never shows stale numbers.
    func evaluate(_ values: [String: Double]) -> [Double]? {
        guard Set(values.keys) == Set(inputs.map(\.id)), inputs.allSatisfy({ input in
            guard let value = values[input.id] else { return false }
            guard value.isFinite, (input.min...input.max).contains(value) else { return false }
            let position = (value - input.min) / input.step
            return input.control != "slider" || abs(position - position.rounded()) < 0.000001
        }) else { return nil }
        var results: [Double] = []
        for output in outputs {
            var stack: [Double] = []
            for token in output.expression {
                if Self.operators.contains(token) {
                    guard let rhs = stack.popLast(), let lhs = stack.popLast() else { return nil }
                    let result: Double
                    switch token {
                    case "+": result = lhs + rhs
                    case "-": result = lhs - rhs
                    case "*": result = lhs * rhs
                    case "/": guard rhs != 0 else { return nil }; result = lhs / rhs
                    case "min": result = Swift.min(lhs, rhs)
                    default: result = Swift.max(lhs, rhs)
                    }
                    guard result.isFinite, abs(result) <= 1e15 else { return nil }
                    stack.append(result)
                } else if let value = values[token] ?? Self.constant(token) { stack.append(value) }
                else { return nil }
            }
            guard stack.count == 1, let result = stack.first else { return nil }
            results.append(result)
        }
        return results
    }

    func formula(for output: Output) -> String {
        var stack: [String] = []
        for token in output.expression {
            if Self.operators.contains(token), let rhs = stack.popLast(), let lhs = stack.popLast() {
                if token == "min" || token == "max" { stack.append("\(token)(\(lhs), \(rhs))") }
                else { stack.append("(\(lhs) \(token == "*" ? "×" : token == "/" ? "÷" : token) \(rhs))") }
            } else { stack.append(inputs.first { $0.id == token }?.label ?? token) }
        }
        return stack.first ?? ""
    }

    static func formatInput(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 340
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    static func parseInput(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No partial parsing, exponent, grouping, currency symbols or trailing junk.
        let separator = locale.decimalSeparator ?? "."
        let normalized = trimmed.replacingOccurrences(of: separator, with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= limit, !text.contains("\0"), !text.contains("```") else { return nil }
        return text
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let text = text(value, limit: 40),
              text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              !operators.contains(text) else { return nil }
        return text
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) <= 1e12 else { return nil }
        return number.doubleValue
    }
    private static func constant(_ text: String) -> Double? {
        guard text.count <= 32, let value = Double(text), value.isFinite, abs(value) <= 1e12 else { return nil }
        return value
    }
    private static func unit(_ value: Any?) -> String? {
        guard let text = value as? String, text.count <= 16, !text.contains("\0"), !text.contains("```") else { return nil }
        return text
    }
}
