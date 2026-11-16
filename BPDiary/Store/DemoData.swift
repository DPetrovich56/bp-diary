#if DEBUG
import Foundation

/// Данные-образцы для автоматических снимков экрана и проверки интерфейса.
/// Включаются аргументом запуска `-demoData` и только в отладочной сборке.
enum DemoData {
    static func requested() -> DiaryData? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demoData") else { return nil }
        var data = make()
        if arguments.contains("-demoOnboarding") {
            data.settings.onboardingDone = false
        }
        return data
    }

    static func make() -> DiaryData {
        var data = DiaryData.initial
        data.settings.onboardingDone = true
        data.settings.weatherEnabled = true
        data.settings.weatherSource = .city
        data.settings.manualCity = ManualCity(name: "Оренбург", latitude: 51.77, longitude: 55.10)

        let morningPill = Medication(
            name: "Лозартан",
            dose: "50 мг",
            note: "после завтрака",
            times: [TimeOfDay(hour: 8, minute: 0)]
        )
        let eveningPill = Medication(
            name: "Амлодипин",
            dose: "5 мг",
            times: [TimeOfDay(hour: 20, minute: 0)]
        )
        let asNeeded = Medication(name: "Каптоприл", dose: "25 мг", note: "при высоком давлении")
        data.medications = [morningPill, eveningPill, asNeeded]

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = Date()

        // Простая детерминированная последовательность вместо случайных чисел:
        // снимки экрана получаются одинаковыми от запуска к запуску.
        var seed: UInt64 = 20261116
        func next(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int((seed >> 33) % span)
        }

        let conditions = [0, 1, 2, 3, 3, 71, 73, 61, 45]
        var entries: [BPEntry] = []
        var intakes: [Intake] = []

        for dayOffset in 0..<21 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let pressureBase = 748 + next(-8...8)
            let temperature = Double(-6 + next(-5...6))

            for (hour, isMorning) in [(8, true), (20, false)] {
                guard let date = calendar.date(
                    bySettingHour: hour,
                    minute: next(2...40),
                    second: 0,
                    of: day
                ) else { continue }
                if date > now { continue }

                let systolic = (isMorning ? 136 : 129) + next(-9...14)
                let diastolic = (isMorning ? 86 : 81) + next(-6...8)
                var entry = BPEntry(systolic: systolic, diastolic: diastolic)
                entry.date = date
                entry.pulse = 66 + next(-6...12)
                entry.healthSynced = true

                let score = systolic >= 145 ? 2 : (systolic >= 135 ? 3 : 4)
                entry.wellbeing = Wellbeing(rawValue: score)
                if systolic >= 145 {
                    entry.symptoms = ["Головная боль"]
                    entry.note = "Плохо спал, с утра болела голова"
                } else if next(0...6) == 0 {
                    entry.symptoms = ["Слабость"]
                }

                let pill = isMorning ? morningPill : eveningPill
                entry.medications = [pill.taken]
                entry.weather = WeatherSnapshot(
                    temperature: temperature + (isMorning ? -2 : 1),
                    pressureMmHg: Double(pressureBase + (isMorning ? 0 : next(-2...2))),
                    pressureChange24h: Double(next(-6...6)),
                    humidity: Double(70 + next(-10...15)),
                    windSpeed: Double(next(1...7)),
                    weatherCode: conditions[next(0...(conditions.count - 1))],
                    place: "Оренбург"
                )
                entries.append(entry)

                let slot = pill.times.first
                intakes.append(
                    Intake(
                        medicationID: pill.id,
                        name: pill.name,
                        dose: pill.dose,
                        date: date.addingTimeInterval(-600),
                        slot: slot
                    )
                )
            }
        }

        data.entries = entries.sorted { $0.date > $1.date }
        data.intakes = intakes.sorted { $0.date > $1.date }
        return data
    }
}
#endif
