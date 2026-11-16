import Foundation
import UIKit

/// Выгрузка дневника в файлы: таблица CSV и отчёт PDF для врача.
enum ExportService {

    // MARK: - Общие форматтеры

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }

    private static func wellbeingText(_ entry: BPEntry) -> String {
        var parts: [String] = []
        if let wellbeing = entry.wellbeing { parts.append(wellbeing.title) }
        if !entry.symptoms.isEmpty { parts.append(entry.symptoms.joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    private static func medicationsText(_ entry: BPEntry) -> String {
        entry.medications.map { $0.title }.joined(separator: ", ")
    }

    private static func temporaryURL(_ fileName: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    // MARK: - CSV

    static func writeCSV(entries: [BPEntry]) throws -> URL {
        let dateFormatter = formatter("dd.MM.yyyy")
        let timeFormatter = formatter("HH:mm")

        func cell(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        var lines: [String] = []
        let header = [
            "Дата", "Время", "Верхнее", "Нижнее", "Пульс", "Категория", "Самочувствие", "Симптомы",
            "Лекарства", "Температура, °C", "Атм. давление, мм рт. ст.", "Изменение за сутки, мм рт. ст.",
            "Влажность, %", "Погода", "Место", "Заметка", "Источник"
        ]
        lines.append(header.map { cell($0) }.joined(separator: ";"))

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            let weather = entry.weather
            var row: [String] = []
            row.append(dateFormatter.string(from: entry.date))
            row.append(timeFormatter.string(from: entry.date))
            row.append(String(entry.systolic))
            row.append(String(entry.diastolic))
            row.append(entry.pulse.map { String($0) } ?? "")
            row.append(entry.category.title)
            row.append(entry.wellbeing?.title ?? "")
            row.append(entry.symptoms.joined(separator: ", "))
            row.append(medicationsText(entry))
            row.append(weather.map { String(Int($0.temperature.rounded())) } ?? "")
            row.append(weather.map { String(Int($0.pressureMmHg.rounded())) } ?? "")
            row.append(weather?.pressureChange24h.map { String(Int($0.rounded())) } ?? "")
            row.append(weather?.humidity.map { String(Int($0.rounded())) } ?? "")
            row.append(weather?.conditionTitle ?? "")
            row.append(weather?.place ?? "")
            row.append(entry.note)
            row.append(entry.isImported ? (entry.healthSourceName ?? "Здоровье") : "Дневник")
            lines.append(row.map { cell($0) }.joined(separator: ";"))
        }

        // BOM нужен, чтобы Excel правильно открыл кириллицу.
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let url = temporaryURL("Дневник давления.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - PDF

    private struct Column {
        let title: String
        let width: CGFloat
    }

    static func writePDF(entries: [BPEntry], periodTitle: String) throws -> URL {
        let sorted = entries.sorted { $0.date < $1.date }
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let margin: CGFloat = 36
        let contentWidth = pageRect.width - margin * 2

        let columns: [Column] = [
            Column(title: "Дата", width: 58),
            Column(title: "Время", width: 38),
            Column(title: "АД", width: 50),
            Column(title: "Пульс", width: 36),
            Column(title: "Самочувствие", width: 121),
            Column(title: "Лекарства", width: 105),
            Column(title: "Погода", width: 115)
        ]

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 18),
            .foregroundColor: UIColor.black
        ]
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.darkGray
        ]

        let dateFormatter = formatter("dd.MM.yy")
        let timeFormatter = formatter("HH:mm")
        let stampFormatter = formatter("d MMMM yyyy")

        func height(of text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            let box = (text as NSString).boundingRect(
                with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            return ceil(box.height)
        }

        let url = temporaryURL("Дневник давления.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        try renderer.writePDF(to: url) { context in
            var y: CGFloat = margin

            func drawLine(at lineY: CGFloat) {
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.lightGray.cgColor)
                cg.setLineWidth(0.5)
                cg.move(to: CGPoint(x: margin, y: lineY))
                cg.addLine(to: CGPoint(x: margin + contentWidth, y: lineY))
                cg.strokePath()
            }

            func drawRow(_ cells: [String], attributes: [NSAttributedString.Key: Any]) -> CGFloat {
                var rowHeight: CGFloat = 0
                for (index, column) in columns.enumerated() where index < cells.count {
                    let cellHeight = height(of: cells[index], width: column.width - 6, attributes: attributes)
                    rowHeight = max(rowHeight, cellHeight)
                }
                var x = margin
                for (index, column) in columns.enumerated() where index < cells.count {
                    let rect = CGRect(x: x + 3, y: y + 3, width: column.width - 6, height: rowHeight)
                    (cells[index] as NSString).draw(in: rect, withAttributes: attributes)
                    x += column.width
                }
                return rowHeight + 6
            }

            func drawTableHeader() {
                let rowHeight = drawRow(columns.map { $0.title }, attributes: headerAttributes)
                y += rowHeight
                drawLine(at: y)
            }

            func startPage() {
                context.beginPage()
                y = margin
            }

            // Заголовок и сводка
            startPage()
            ("Дневник артериального давления" as NSString).draw(
                at: CGPoint(x: margin, y: y),
                withAttributes: titleAttributes
            )
            y += 26

            var summary: [String] = []
            summary.append("Период: \(periodTitle). Сформировано \(stampFormatter.string(from: Date())).")
            if sorted.isEmpty {
                summary.append("За выбранный период записей нет.")
            } else {
                let systolicValues: [Int] = sorted.map { $0.systolic }
                let diastolicValues: [Int] = sorted.map { $0.diastolic }
                let averageSystolic: Int = Statistics.average(systolicValues) ?? 0
                let averageDiastolic: Int = Statistics.average(diastolicValues) ?? 0
                let maxSystolic: Int = systolicValues.max() ?? 0
                let minSystolic: Int = systolicValues.min() ?? 0
                let maxDiastolic: Int = diastolicValues.max() ?? 0
                let minDiastolic: Int = diastolicValues.min() ?? 0
                let elevated: Int = sorted.filter { $0.systolic >= 140 || $0.diastolic >= 90 }.count
                summary.append("Замеров: \(sorted.count). Среднее давление: \(averageSystolic)/\(averageDiastolic) мм рт. ст.")
                summary.append("Верхнее: от \(minSystolic) до \(maxSystolic). Нижнее: от \(minDiastolic) до \(maxDiastolic).")
                summary.append("Замеров 140/90 и выше: \(elevated) из \(sorted.count).")
                let pulses: [Int] = sorted.compactMap { $0.pulse }
                if let averagePulse = Statistics.average(pulses) {
                    summary.append("Средний пульс: \(averagePulse) уд/мин.")
                }
            }
            for line in summary {
                (line as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: textAttributes)
                y += 13
            }
            y += 8

            guard !sorted.isEmpty else { return }
            drawTableHeader()

            for entry in sorted {
                let cells: [String] = [
                    dateFormatter.string(from: entry.date),
                    timeFormatter.string(from: entry.date),
                    entry.pressureTitle,
                    entry.pulse.map { String($0) } ?? "—",
                    wellbeingText(entry),
                    medicationsText(entry),
                    entry.weather?.summary ?? ""
                ]

                var estimated: CGFloat = 0
                for (index, column) in columns.enumerated() {
                    estimated = max(estimated, height(of: cells[index], width: column.width - 6, attributes: textAttributes))
                }
                estimated += 6
                let noteHeight: CGFloat = entry.note.isEmpty
                    ? 0
                    : height(of: "Заметка: " + entry.note, width: contentWidth - 6, attributes: noteAttributes) + 4

                if y + estimated + noteHeight > pageRect.height - margin {
                    startPage()
                    drawTableHeader()
                }

                let rowHeight = drawRow(cells, attributes: textAttributes)
                y += rowHeight

                if !entry.note.isEmpty {
                    let rect = CGRect(x: margin + 3, y: y - 2, width: contentWidth - 6, height: noteHeight)
                    (("Заметка: " + entry.note) as NSString).draw(in: rect, withAttributes: noteAttributes)
                    y += noteHeight
                }
                drawLine(at: y)
            }
        }
        return url
    }
}
