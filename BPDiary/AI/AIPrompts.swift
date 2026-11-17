import Foundation

/// Обезличенная сводка дневника для ИИ и тексты инструкций.
///
/// В сводку НЕ попадают: имя и любые контакты (приложение их и не хранит), город и координаты,
/// названия приборов и приложений из «Здоровья». Заметки — только если пользователь разрешил.
enum AIPrompts {

    // MARK: - Инструкции

    static let analysisInstructions = """
    Ты — внимательный помощник, который разбирает дневник артериального давления пользователя. \
    Ты не врач и не заменяешь врача.

    Правила:
    — Опирайся только на данные из сообщения. Все средние значения и подсчёты уже сделаны приложением — бери цифры оттуда, не пересчитывай и не придумывай.
    — Не ставь диагнозы. Не назначай, не отменяй и не заменяй лекарства, не меняй дозировки и время приёма — это решает только врач. Можно предложить обсудить вопрос с врачом.
    — Если есть замеры 180/110 и выше или жалобы на боль в груди, одышку, сильную головную боль, нарушение речи или слабость в руке или ноге, первым пунктом напиши, что при таком состоянии нужно срочно вызвать скорую: 103 или 112.
    — Если данных мало для вывода, так и скажи.
    — Пиши по-русски, простым языком, без лишних терминов.

    Структура ответа:
    1. Главное — 2–3 предложения.
    2. Давление и пульс: уровень, разброс, динамика, утро и вечер.
    3. Лекарства: регулярность приёма и как давление выглядит в дни с пропусками и без.
    4. Самочувствие и погода: есть ли заметная связь.
    5. На что обратить внимание.
    6. Вопросы, которые стоит обсудить с врачом.

    В конце одной строкой: «Это не медицинское заключение. Решения о лечении принимает врач.»
    """

    static func medicationInstructions(hasLeaflet: Bool, webSearch: Bool) -> String {
        var source: String
        if hasLeaflet {
            source = "Опирайся только на текст инструкции из сообщения. Если нужного раздела в тексте нет, так и напиши, не дополняй по памяти."
        } else if webSearch {
            source = "Найди официальную инструкцию по медицинскому применению (приоритет: Государственный реестр лекарственных средств grls.rosminzdrav.ru, затем vidal.ru, rlsnet.ru) и опирайся на неё. Укажи источники."
        } else {
            source = "Отвечай по своим знаниям. В начале ответа предупреди, что сведения не сверены с инструкцией и их нужно проверить по вкладышу в упаковке."
        }
        return """
        Ты — помощник, который объясняет инструкции к лекарствам простым языком. Ты не врач.

        \(source)

        Правила:
        — Дозировки приводи только так, как они указаны в инструкции, без расчёта под конкретного человека и без советов менять дозу.
        — Не советуй начинать, прекращать или заменять лекарство — это решает врач.
        — Если у пользователя есть другие лекарства, проверь взаимодействия именно с ними.
        — Пиши по-русски, кратко, по разделам.

        Разделы ответа:
        1. Что это за препарат: действующее вещество, группа, для чего применяется.
        2. Показания.
        3. Противопоказания.
        4. Как принимать по инструкции: обычные дозировки и правила приёма.
        5. Побочные эффекты: частые и те, при которых нужно срочно к врачу.
        6. Взаимодействие с другими лекарствами пользователя.
        7. Что уточнить у врача или фармацевта.

        В конце одной строкой: «Сверьтесь с инструкцией в упаковке и обсудите приём с врачом.»
        """
    }

    // MARK: - Сводка дневника

    enum Detail {
        /// Все замеры построчно (для облачных моделей).
        case full
        /// По дням, не больше 30 дней (для встроенной модели с небольшим окном контекста).
        case compact
    }

    static func diarySummary(
        entries allEntries: [BPEntry],
        medications: [Medication],
        intakes allIntakes: [Intake],
        days: Int,
        detail: Detail,
        includeNotes: Bool,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar.current
        let effectiveDays = detail == .compact ? min(days, 30) : days
        let start = calendar.date(byAdding: .day, value: -effectiveDays, to: calendar.startOfDay(for: now)) ?? now
        let entries = allEntries.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        let intakes = allIntakes.filter { $0.date >= start && $0.date <= now }

        let dayFormatter = formatter("dd.MM")
        let timeFormatter = formatter("HH:mm")

        var lines: [String] = []
        lines.append("ДНЕВНИК ДАВЛЕНИЯ за последние \(effectiveDays) дн. (по \(formatter("dd.MM.yyyy").string(from: now)))")
        lines.append("")

        // Сводка
        lines.append("СВОДКА (посчитано приложением):")
        if let summary = Statistics.summary(of: entries) {
            lines.append("— Замеров: \(summary.count). Среднее давление: \(summary.averageSystolic)/\(summary.averageDiastolic) мм рт. ст.")
            if let pulse = summary.averagePulse {
                lines.append("— Средний пульс: \(pulse) уд/мин.")
            }
            lines.append("— Верхнее от \(summary.minSystolic) до \(summary.maxSystolic), нижнее от \(summary.minDiastolic) до \(summary.maxDiastolic).")
            lines.append("— Замеров 140/90 и выше: \(summary.elevatedCount) из \(summary.count).")
            let severe = entries.filter { $0.systolic >= 180 || $0.diastolic >= 110 }.count
            if severe > 0 { lines.append("— Замеров 180/110 и выше: \(severe).") }
            let low = entries.filter { $0.systolic < 90 || $0.diastolic < 60 }.count
            if low > 0 { lines.append("— Замеров ниже 90/60: \(low).") }

            for part in Statistics.DayPart.allCases {
                if let partSummary = Statistics.summary(of: Statistics.entries(entries, in: part)) {
                    lines.append("— \(part.rawValue): среднее \(partSummary.averageSystolic)/\(partSummary.averageDiastolic), замеров \(partSummary.count).")
                }
            }

            if entries.count >= 6 {
                let half = entries.count / 2
                if let first = Statistics.summary(of: Array(entries[..<half])),
                   let second = Statistics.summary(of: Array(entries[half...])) {
                    lines.append("— Первая половина периода: \(first.averageSystolic)/\(first.averageDiastolic); вторая: \(second.averageSystolic)/\(second.averageDiastolic).")
                }
            }

            appendWellbeing(entries, to: &lines)
            appendWeather(entries, to: &lines)
        } else {
            lines.append("— За период замеров нет.")
        }
        lines.append("")

        // Лекарства
        lines.append("ЛЕКАРСТВА:")
        if medications.isEmpty {
            lines.append("— Не указаны.")
        } else {
            let daysInPeriod = max(1, effectiveDays)
            var adherenceByDay: [Date: Bool] = [:]
            for medication in medications {
                var line = "— \(medication.title)"
                if !medication.note.isEmpty { line += " (\(medication.note))" }
                if medication.times.isEmpty {
                    let count = intakes.filter { $0.medicationID == medication.id }.count
                    line += ": по необходимости, принято за период \(count) раз."
                } else {
                    let times = medication.times.sorted().map { $0.title }.joined(separator: ", ")
                    let planned = medication.times.count * daysInPeriod
                    let taken = intakes.filter { $0.medicationID == medication.id && $0.slot != nil }.count
                    line += ": по расписанию в \(times); отмечено приёмов \(taken) из \(planned) запланированных."
                }
                lines.append(line)
            }
            // Дни, когда все плановые приёмы отмечены, и дни с пропусками.
            let scheduled = medications.filter { !$0.times.isEmpty }
            if !scheduled.isEmpty {
                let readingDays = Set(entries.map { calendar.startOfDay(for: $0.date) })
                for day in readingDays {
                    var complete = true
                    for medication in scheduled {
                        for time in medication.times {
                            let done = intakes.contains {
                                $0.medicationID == medication.id && $0.slot == time
                                    && calendar.isDate($0.date, inSameDayAs: day)
                            }
                            if !done { complete = false }
                        }
                    }
                    adherenceByDay[day] = complete
                }
                let fullDays = entries.filter { adherenceByDay[calendar.startOfDay(for: $0.date)] == true }
                let missedDays = entries.filter { adherenceByDay[calendar.startOfDay(for: $0.date)] == false }
                if let full = Statistics.summary(of: fullDays) {
                    lines.append("— В дни, когда все плановые приёмы отмечены: среднее \(full.averageSystolic)/\(full.averageDiastolic) (замеров \(full.count)).")
                }
                if let missed = Statistics.summary(of: missedDays) {
                    lines.append("— В дни с пропущенными или неотмеченными приёмами: среднее \(missed.averageSystolic)/\(missed.averageDiastolic) (замеров \(missed.count)).")
                }
            }
        }
        lines.append("")

        // Замеры
        switch detail {
        case .full:
            lines.append("ЗАМЕРЫ (дата, время | давление | пульс | самочувствие | лекарства | погода):")
            for entry in entries {
                lines.append(entryLine(entry, day: dayFormatter, time: timeFormatter, includeNotes: includeNotes))
            }
        case .compact:
            lines.append("ЗАМЕРЫ ПО ДНЯМ:")
            let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            for day in grouped.keys.sorted() {
                let items = (grouped[day] ?? []).sorted { $0.date < $1.date }
                let readings = items.map { "\(timeFormatter.string(from: $0.date)) \($0.pressureTitle)" }.joined(separator: ", ")
                var extra: [String] = []
                let symptoms = Set(items.flatMap { $0.symptoms })
                if !symptoms.isEmpty { extra.append(symptoms.sorted().joined(separator: ", ").lowercased()) }
                if let worst = items.compactMap({ $0.wellbeing }).min(by: { $0.rawValue < $1.rawValue }), worst.rawValue <= 2 {
                    extra.append("самочувствие: \(worst.title.lowercased())")
                }
                if includeNotes {
                    let notes = items.map { $0.note }.filter { !$0.isEmpty }
                    if !notes.isEmpty { extra.append("заметки: " + notes.joined(separator: "; ")) }
                }
                let tail = extra.isEmpty ? "" : " — " + extra.joined(separator: "; ")
                lines.append("\(dayFormatter.string(from: day)): \(readings)\(tail)")
            }
        }
        if entries.isEmpty {
            lines.append("— нет")
        }
        return lines.joined(separator: "\n")
    }

    private static func entryLine(_ entry: BPEntry, day: DateFormatter, time: DateFormatter, includeNotes: Bool) -> String {
        var parts: [String] = []
        parts.append("\(day.string(from: entry.date)) \(time.string(from: entry.date))")
        parts.append(entry.pressureTitle)
        parts.append(entry.pulse.map { "пульс \($0)" } ?? "пульс —")

        var feeling: [String] = []
        if let wellbeing = entry.wellbeing { feeling.append(wellbeing.title.lowercased()) }
        feeling.append(contentsOf: entry.symptoms.map { $0.lowercased() })
        parts.append(feeling.isEmpty ? "—" : feeling.joined(separator: ", "))

        parts.append(entry.medications.isEmpty ? "—" : entry.medications.map { $0.title }.joined(separator: ", "))

        if let weather = entry.weather {
            var items: [String] = [weather.temperatureTitle, "\(Int(weather.pressureMmHg.rounded())) мм"]
            if let change = weather.pressureChange24h {
                let rounded = Int(change.rounded())
                items.append(rounded >= 0 ? "+\(rounded) за сутки" : "\(rounded) за сутки")
            }
            if let humidity = weather.humidity { items.append("\(Int(humidity.rounded()))%") }
            parts.append(items.joined(separator: " "))
        } else {
            parts.append("—")
        }

        var line = parts.joined(separator: " | ")
        if includeNotes, !entry.note.isEmpty {
            line += " | заметка: \(entry.note)"
        }
        return line
    }

    private static func appendWellbeing(_ entries: [BPEntry], to lines: inout [String]) {
        let bad = entries.filter { ($0.wellbeing?.rawValue ?? 3) <= 2 }
        let good = entries.filter { ($0.wellbeing?.rawValue ?? 0) >= 4 }
        if let badSummary = Statistics.summary(of: bad), let goodSummary = Statistics.summary(of: good) {
            lines.append("— При плохом самочувствии: среднее \(badSummary.averageSystolic)/\(badSummary.averageDiastolic) (замеров \(badSummary.count)); при хорошем: \(goodSummary.averageSystolic)/\(goodSummary.averageDiastolic) (замеров \(goodSummary.count)).")
        }
        var counts: [String: Int] = [:]
        for entry in entries {
            for symptom in entry.symptoms { counts[symptom, default: 0] += 1 }
        }
        if !counts.isEmpty {
            let top = counts.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key.lowercased()) — \($0.value)" }
                .joined(separator: ", ")
            lines.append("— Симптомы (сколько раз отмечены): \(top).")
        }
    }

    private static func appendWeather(_ entries: [BPEntry], to lines: inout [String]) {
        let withChange = entries.filter { $0.weather?.pressureChange24h != nil }
        guard withChange.count >= 4 else { return }
        let falling = withChange.filter { ($0.weather?.pressureChange24h ?? 0) <= -4 }
        let rising = withChange.filter { ($0.weather?.pressureChange24h ?? 0) >= 4 }
        let stable = withChange.filter { abs($0.weather?.pressureChange24h ?? 0) < 4 }
        var parts: [String] = []
        if let s = Statistics.summary(of: falling) { parts.append("при падении атм. давления на 4+ мм за сутки \(s.averageSystolic)/\(s.averageDiastolic) (\(s.count))") }
        if let s = Statistics.summary(of: rising) { parts.append("при росте на 4+ мм \(s.averageSystolic)/\(s.averageDiastolic) (\(s.count))") }
        if let s = Statistics.summary(of: stable) { parts.append("при стабильном \(s.averageSystolic)/\(s.averageDiastolic) (\(s.count))") }
        if parts.count >= 2 {
            lines.append("— Давление и погода: " + parts.joined(separator: "; ") + ".")
        }
    }

    // MARK: - Запрос о лекарстве

    static func medicationRequest(name: String, otherMedications: [String], leafletText: String?) -> String {
        var lines: [String] = []
        lines.append("Препарат: \(name)")
        if otherMedications.isEmpty {
            lines.append("Другие лекарства пользователя: не указаны.")
        } else {
            lines.append("Другие лекарства пользователя: \(otherMedications.joined(separator: ", ")).")
        }
        if let leafletText, !leafletText.isEmpty {
            lines.append("")
            lines.append("ТЕКСТ ИНСТРУКЦИИ (распознан с фотографии вкладыша):")
            lines.append(leafletText)
        }
        return lines.joined(separator: "\n")
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }
}
