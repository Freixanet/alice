import SwiftUI

/// Native, local scenario exploration. Edits stay in this mounted snapshot;
/// the original transcript remains the agent's immutable input.
struct NativeCalculatorView: View {
    @Environment(\.colorScheme) private var scheme
    let calculator: NativeCalculator
    var language: ChatLanguage = .english
    @State private var fields: [String: String] = [:]
    @FocusState private var focused: String?

    init(calculator: NativeCalculator, language: ChatLanguage = .english) {
        self.calculator = calculator
        self.language = language
        _fields = State(initialValue: Dictionary(uniqueKeysWithValues: calculator.inputs.map {
            ($0.id, NativeCalculator.formatInput($0.value))
        }))
    }

    private var spanish: Bool { language == .spanish }
    private var values: [String: Double] {
        Dictionary(uniqueKeysWithValues: calculator.inputs.compactMap { input in
            NativeCalculator.parseInput(fields[input.id] ?? "").map { (input.id, $0) }
        })
    }
    private var results: [Double]? { calculator.evaluate(values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(calculator.title).font(.headline)
                    Text(calculator.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    focused = nil
                    fields = Dictionary(uniqueKeysWithValues: calculator.inputs.map { ($0.id, editable($0.value)) })
                } label: { Image(systemName: "arrow.counterclockwise").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(spanish ? "Restablecer valores" : "Reset values")
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(calculator.outputs.enumerated()), id: \.element.id) { index, output in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(output.label).font(.caption).foregroundStyle(.secondary)
                        Text(results.map { amount($0[index], unit: output.unit) } ?? "—")
                            .font(index == 0 ? .title.weight(.semibold) : .title3.weight(.medium))
                            .monospacedDigit().foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
            if results == nil {
                Label(spanish ? "Revisa los valores y evita dividir entre cero." : "Check the values and avoid dividing by zero.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 18) {
                ForEach(calculator.inputs) { input in
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text(input.label).font(.subheadline)
                                Spacer(minLength: 8)
                                editor(input)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(input.label).font(.subheadline)
                                editor(input)
                            }
                        }
                        if input.control == "slider" {
                            Slider(value: Binding(get: { min(input.max, max(input.min, values[input.id] ?? input.value)) }, set: { fields[input.id] = editable($0) }),
                                   in: input.min...input.max, step: input.step)
                                .accessibilityLabel(input.label)
                            HStack {
                                Text(amount(input.min, unit: input.unit))
                                Spacer()
                                Text(amount(input.max, unit: input.unit))
                            }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let value = values[input.id], !(input.min...input.max).contains(value) {
                            Text("\(amount(input.min, unit: input.unit)) – \(amount(input.max, unit: input.unit))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            DisclosureGroup(spanish ? "Cómo se calcula" : "How it is calculated") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(calculator.outputs) { output in
                        Text("\(output.label): \(calculator.formula(for: output))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.footnote)
            Text(spanish ? "Los cambios se calculan aquí, sin usar tu cuota." : "Changes calculate here without using your quota.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .componentCard(scheme)
        .toolbar {
            if focused != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(spanish ? "Listo" : "Done") { focused = nil }
                }
            }
        }
    }

    private func editor(_ input: NativeCalculator.Input) -> some View {
        HStack(spacing: 6) {
            TextField(input.label, text: Binding(get: { fields[input.id] ?? "" }, set: { fields[input.id] = $0 }))
                .keyboardType(input.min < 0 ? .numbersAndPunctuation : .decimalPad)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .focused($focused, equals: input.id)
                .accessibilityLabel(input.label)
                .accessibilityHint("\(input.min) – \(input.max) \(input.unit)")
            if !input.unit.isEmpty { Text(input.unit).foregroundStyle(.secondary) }
        }
        .font(.body).padding(.horizontal, 12).frame(width: 154).frame(minHeight: 44)
        .background(Palette.background(scheme), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Palette.border(scheme), lineWidth: 0.5) }
    }
    private func editable(_ value: Double) -> String {
        NativeCalculator.formatInput(value)
    }
    private func amount(_ value: Double, unit: String) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}
