import SwiftUI
import Charts

/// Вкладка «Графики»: динамика давления, пульса и атмосферного давления.
struct StatsView: View {
    @EnvironmentObject private var store: DiaryStore

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .week: return "7 дней"
            case .month: return "30 дней"
            case .quarter: return "90 дней"
            }
        }
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: String
    }

    private static let systolicName = "Верхнее"
    private static let diastolicName = "Нижнее"

    @State private var period: Period = .month

    private var entries: [BPEntry] {
        store.entries(inLast: period.rawValue).sorted { $0.date < $1.date }
    }

    private var pressurePoints: [ChartPoint] {
        var points: [ChartPoint] = []
        for entry in entries {
            points.append(ChartPoint(date: entry.date, value: Double(entry.systolic), series: StatsView.systolicName))
            points.append(ChartPoint(date: entry.date, value: Double(entry.diastolic), series: StatsView.diastolicName))
        }
        return points
    }

    private var pulsePoints: [ChartPoint] {
        var points: [ChartPoint] = []
        for entry in entries {
            if let pulse = entry.pulse {
                points.append(ChartPoint(date: entry.date, value: Double(pulse), series: "Пульс"))
            }
        }
        return points
    }

    private var weatherPoints: [ChartPoint] {
        var points: [ChartPoint] = []
        for entry in entries {
            if let weather = entry.weather {
                points.append(ChartPoint(date: entry.date, value: weather.pressureMmHg, series: "Атмосферное давление"))
            }
        }
        return points
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Период", selection: $period) {
                        ForEach(Period.allCases) { item in
                            Text(verbatim: item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let summary = Statistics.summary(of: entries) {
                    summarySection(summary)
                    pressureChartSection
                    pulseChartSection
                    weatherChartSection
                    dayPartsSection
                    Section {
                        Text("Пунктиром отмечен уровень 140/90. Оценка замеров и целевые значения — вопрос к лечащему врачу.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("За выбранный период записей нет.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Графики")
        }
    }

    // MARK: - Сводка

    private func summarySection(_ summary: Statistics.Summary) -> some View {
        Section {
            LabeledContent("Среднее давление") {
                Text(verbatim: "\(summary.averageSystolic)/\(summary.averageDiastolic)")
                    .monospacedDigit()
            }
            if let pulse = summary.averagePulse {
                LabeledContent("Средний пульс") {
                    Text(verbatim: "\(pulse)")
                        .monospacedDigit()
                }
            }
            LabeledContent("Верхнее, от и до") {
                Text(verbatim: "\(summary.minSystolic)–\(summary.maxSystolic)")
                    .monospacedDigit()
            }
            LabeledContent("Нижнее, от и до") {
                Text(verbatim: "\(summary.minDiastolic)–\(summary.maxDiastolic)")
                    .monospacedDigit()
            }
            LabeledContent("Замеров 140/90 и выше") {
                Text(verbatim: "\(summary.elevatedCount) из \(summary.count)")
                    .monospacedDigit()
            }
        } header: {
            Text("Сводка")
        }
    }

    // MARK: - Графики

    private var pressureDomain: ClosedRange<Double> {
        let values = pressurePoints.map { $0.value }
        let low: Double = min(values.min() ?? 60, 60)
        let high: Double = max(values.max() ?? 160, 160)
        return (low - 10)...(high + 10)
    }

    private var pressureChartSection: some View {
        Section {
            Chart {
                ForEach(pressurePoints) { point in
                    LineMark(
                        x: .value("Дата", point.date),
                        y: .value("мм рт. ст.", point.value),
                        series: .value("Показатель", point.series)
                    )
                    .foregroundStyle(by: .value("Показатель", point.series))
                    .interpolationMethod(.linear)

                    PointMark(
                        x: .value("Дата", point.date),
                        y: .value("мм рт. ст.", point.value)
                    )
                    .foregroundStyle(by: .value("Показатель", point.series))
                    .symbolSize(30)
                }

                RuleMark(y: .value("Порог", 140.0))
                    .foregroundStyle(Color.red.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(y: .value("Порог", 90.0))
                    .foregroundStyle(Color.blue.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartForegroundStyleScale([
                StatsView.systolicName: Color.red,
                StatsView.diastolicName: Color.blue
            ])
            .chartYScale(domain: pressureDomain)
            .frame(height: 240)
            .padding(.vertical, 6)
        } header: {
            Text("Давление, мм рт. ст.")
        }
    }

    @ViewBuilder
    private var pulseChartSection: some View {
        if pulsePoints.count >= 2 {
            Section {
                Chart {
                    ForEach(pulsePoints) { point in
                        LineMark(
                            x: .value("Дата", point.date),
                            y: .value("уд/мин", point.value)
                        )
                        .foregroundStyle(Color.pink)
                        PointMark(
                            x: .value("Дата", point.date),
                            y: .value("уд/мин", point.value)
                        )
                        .foregroundStyle(Color.pink)
                        .symbolSize(30)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                .padding(.vertical, 6)
            } header: {
                Text("Пульс, уд/мин")
            }
        }
    }

    @ViewBuilder
    private var weatherChartSection: some View {
        if weatherPoints.count >= 2 {
            Section {
                Chart {
                    ForEach(weatherPoints) { point in
                        LineMark(
                            x: .value("Дата", point.date),
                            y: .value("мм рт. ст.", point.value)
                        )
                        .foregroundStyle(Color.gray)
                        PointMark(
                            x: .value("Дата", point.date),
                            y: .value("мм рт. ст.", point.value)
                        )
                        .foregroundStyle(Color.gray)
                        .symbolSize(30)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                .padding(.vertical, 6)
            } header: {
                Text("Атмосферное давление, мм рт. ст.")
            } footer: {
                Text("По данным погоды, сохранённым вместе с замерами. Сравните с графиком давления выше.")
            }
        }
    }

    // MARK: - Время суток

    private var dayPartsSection: some View {
        Section {
            ForEach(Statistics.DayPart.allCases) { part in
                let subset = Statistics.entries(entries, in: part)
                LabeledContent(part.rawValue) {
                    if let summary = Statistics.summary(of: subset) {
                        Text(verbatim: "\(summary.averageSystolic)/\(summary.averageDiastolic)")
                            .monospacedDigit()
                    } else {
                        Text(verbatim: "—")
                    }
                }
            }
        } header: {
            Text("Среднее по времени суток")
        }
    }
}
