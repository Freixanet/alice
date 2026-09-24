import Foundation
import HealthKit

/// Daily summaries from the Health app for the person's own Hermes
/// (hermes-plugin/health.py): sleep, steps, active energy, workout minutes,
/// resting heart rate and HRV. Anything that writes to Health — a WHOOP, an
/// Apple Watch — arrives with it. Read-only; one row per day, never samples.
enum HealthSync {
    static let store = HKHealthStore()

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let reads: Set<HKObjectType> = [
        HKCategoryType(.sleepAnalysis),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKObjectType.workoutType(),
        HKCategoryType(.mindfulSession),
        // Not here: medication doses are shared per medication, with their own
        // sheet below. Asking for them in this set makes HealthKit throw — it
        // closed the app on Connect.
    ]

    /// iOS shows its own sheet; it never says what was allowed for reading,
    /// so a connection is judged by whether any data comes back.
    static func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: reads)
        // Medications are shared one by one: iOS lists them and the person picks.
        try? await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
    }

    /// The last `days` days, one dictionary each, keyed as health.py reads them.
    static func days(_ days: Int = 60, now: Date = .now) async -> [[String: Any]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        async let steps = sums(.stepCount, unit: .count(), from: start, to: end)
        async let energy = sums(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        async let resting = averages(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let hrv = averages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: start, to: end)
        async let sleep = sleepHours(from: calendar.date(byAdding: .hour, value: -12, to: start) ?? start, to: end)
        async let workouts = workoutMinutes(from: start, to: end)
        async let mindful = mindfulMinutes(from: start, to: end)
        async let meds = medication(from: start, to: min(end, now))
        let doses = await meds
        let columns: [(String, [Date: Double])] = await [
            ("steps", steps), ("active_kcal", energy), ("rhr", resting), ("hrv", hrv),
            ("sleep_h", sleep), ("workout_min", workouts), ("mindful_min", mindful),
            ("meds_due", doses.due), ("meds_taken", doses.taken),
        ]
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        var rows: [Date: [String: Any]] = [:]
        for (key, values) in columns {
            for (day, value) in values where day >= start && day < end {
                rows[day, default: ["date": format.string(from: day)]][key] = (value * 100).rounded() / 100
            }
        }
        for (day, names) in doses.missed where day >= start && day < end && !names.isEmpty {
            rows[day, default: ["date": format.string(from: day)]]["meds_missed"] = names
        }
        return rows.keys.sorted().compactMap { rows[$0] }.filter { $0.count > 1 }
    }

    // MARK: Queries

    private static func collection(
        _ id: HKQuantityTypeIdentifier, options: HKStatisticsOptions, from start: Date, to end: Date
    ) async -> HKStatisticsCollection? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: options, anchorDate: start, intervalComponents: DateComponents(day: 1))
        return try? await query.result(for: store)
    }

    /// Per-day totals; Health merges overlapping sources (phone and watch) itself.
    private static func sums(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async -> [Date: Double] {
        guard let result = await collection(id, options: .cumulativeSum, from: start, to: end) else { return [:] }
        var out: [Date: Double] = [:]
        result.enumerateStatistics(from: start, to: end) { stats, _ in
            if let value = stats.sumQuantity()?.doubleValue(for: unit), value > 0 { out[stats.startDate] = value }
        }
        return out
    }

    private static func averages(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async -> [Date: Double] {
        guard let result = await collection(id, options: .discreteAverage, from: start, to: end) else { return [:] }
        var out: [Date: Double] = [:]
        result.enumerateStatistics(from: start, to: end) { stats, _ in
            if let value = stats.averageQuantity()?.doubleValue(for: unit) { out[stats.startDate] = value }
        }
        return out
    }

    /// Hours asleep per night, counted on the day the person woke up. Each
    /// source is summed on its own and the fullest one kept: a WHOOP and a
    /// watch recording the same night must not add up to two nights.
    private static func sleepHours(from start: Date, to end: Date) async -> [Date: Double] {
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [])
        guard let samples = try? await query.result(for: store) else { return [:] }
        let calendar = Calendar.current
        var bySource: [String: [Date: Double]] = [:]
        for sample in samples where asleep.contains(sample.value) {
            let day = calendar.startOfDay(for: sample.endDate)
            let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
            bySource[sample.sourceRevision.source.bundleIdentifier, default: [:]][day, default: 0] += hours
        }
        var out: [Date: Double] = [:]
        for nights in bySource.values {
            for (day, hours) in nights where hours < 16 { out[day] = max(out[day] ?? 0, hours) }
        }
        return out
    }

    private static func mindfulMinutes(from start: Date, to end: Date) async -> [Date: Double] {
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.mindfulSession),
                                         predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [])
        guard let samples = try? await query.result(for: store) else { return [:] }
        var out: [Date: Double] = [:]
        for sample in samples {
            out[Calendar.current.startOfDay(for: sample.startDate), default: 0] +=
                sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        return out
    }

    /// Scheduled doses per day, how many were logged as taken, and the names of
    /// the ones not taken on days already over (today is still open).
    private static func medication(from start: Date, to end: Date)
        async -> (due: [Date: Double], taken: [Date: Double], missed: [Date: [String]]) {
        let calendar = Calendar.current
        var names: [String: String] = [:]
        if let meds = try? await HKUserAnnotatedMedicationQueryDescriptor().result(for: store) {
            for med in meds {
                names[med.medication.identifier.description] = med.nickname ?? med.medication.displayText
            }
        }
        let query = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKObjectType.medicationDoseEventType(),
                                 predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [])
        guard let samples = try? await query.result(for: store) else { return ([:], [:], [:]) }
        var due: [Date: Double] = [:], taken: [Date: Double] = [:], missed: [Date: [String]] = [:]
        let today = calendar.startOfDay(for: .now)
        for case let dose as HKMedicationDoseEvent in samples {
            guard dose.scheduleType == .schedule else { continue }
            let day = calendar.startOfDay(for: dose.scheduledDate ?? dose.startDate)
            due[day, default: 0] += 1
            if dose.logStatus == .taken {
                taken[day, default: 0] += 1
            } else if day < today {
                let name = names[dose.medicationConceptIdentifier.description] ?? String(localized: "Medication")
                if !(missed[day] ?? []).contains(name) { missed[day, default: []].append(name) }
            }
        }
        return (due, taken, missed)
    }

    private static func workoutMinutes(from start: Date, to end: Date) async -> [Date: Double] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))], sortDescriptors: [])
        guard let workouts = try? await query.result(for: store) else { return [:] }
        let calendar = Calendar.current
        // Per source, then the fullest: the same run from a WHOOP and a watch counts once.
        var bySource: [String: [Date: Double]] = [:]
        for workout in workouts {
            bySource[workout.sourceRevision.source.bundleIdentifier, default: [:]][
                calendar.startOfDay(for: workout.startDate), default: 0] += workout.duration / 60
        }
        var out: [Date: Double] = [:]
        for days in bySource.values {
            for (day, minutes) in days { out[day] = max(out[day] ?? 0, minutes) }
        }
        return out
    }
}
