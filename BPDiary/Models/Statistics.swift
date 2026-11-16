import Foundation

/// Простая статистика по записям дневника.
enum Statistics {
    /// Среднее арифметическое, округлённое до целого. `nil`, если значений нет.
    static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let total: Int = values.reduce(0, +)
        let mean: Double = Double(total) / Double(values.count)
        return Int(mean.rounded())
    }

    struct Summary {
        let count: Int
        let averageSystolic: Int
        let averageDiastolic: Int
        let averagePulse: Int?
        let minSystolic: Int
        let maxSystolic: Int
        let minDiastolic: Int
        let maxDiastolic: Int
        /// Число замеров 140/90 и выше.
        let elevatedCount: Int
    }

    static func summary(of entries: [BPEntry]) -> Summary? {
        guard !entries.isEmpty else { return nil }
        let systolic: [Int] = entries.map { $0.systolic }
        let diastolic: [Int] = entries.map { $0.diastolic }
        let pulses: [Int] = entries.compactMap { $0.pulse }
        let elevated: Int = entries.filter { $0.systolic >= 140 || $0.diastolic >= 90 }.count
        return Summary(
            count: entries.count,
            averageSystolic: average(systolic) ?? 0,
            averageDiastolic: average(diastolic) ?? 0,
            averagePulse: average(pulses),
            minSystolic: systolic.min() ?? 0,
            maxSystolic: systolic.max() ?? 0,
            minDiastolic: diastolic.min() ?? 0,
            maxDiastolic: diastolic.max() ?? 0,
            elevatedCount: elevated
        )
    }

    /// Часть суток для сравнения утренних и вечерних замеров.
    enum DayPart: String, CaseIterable, Identifiable {
        case morning = "Утро (до 12:00)"
        case day = "День (12:00–18:00)"
        case evening = "Вечер (после 18:00)"

        var id: String { rawValue }

        static func of(_ date: Date) -> DayPart {
            let hour = Calendar.current.component(.hour, from: date)
            if hour < 12 { return .morning }
            if hour < 18 { return .day }
            return .evening
        }
    }

    static func entries(_ entries: [BPEntry], in part: DayPart) -> [BPEntry] {
        entries.filter { DayPart.of($0.date) == part }
    }
}
