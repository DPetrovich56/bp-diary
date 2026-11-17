import Foundation

// MARK: - Время суток (для расписаний)

struct TimeOfDay: Codable, Hashable, Comparable, Identifiable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.hour = components.hour ?? 8
        self.minute = components.minute ?? 0
    }

    var id: Int { hour * 60 + minute }

    var title: String { String(format: "%02d:%02d", hour, minute) }

    func date(on day: Date = Date()) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.id < rhs.id }
}

// MARK: - Самочувствие

enum Wellbeing: Int, Codable, CaseIterable, Identifiable {
    case veryBad = 1
    case bad = 2
    case normal = 3
    case good = 4
    case excellent = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .veryBad: return "Очень плохо"
        case .bad: return "Плохо"
        case .normal: return "Нормально"
        case .good: return "Хорошо"
        case .excellent: return "Отлично"
        }
    }

    var emoji: String {
        switch self {
        case .veryBad: return "😣"
        case .bad: return "🙁"
        case .normal: return "😐"
        case .good: return "🙂"
        case .excellent: return "😀"
        }
    }
}

enum SymptomCatalog {
    static let all: [String] = [
        "Головная боль",
        "Головокружение",
        "Шум в ушах",
        "Тошнота",
        "Слабость",
        "Сердцебиение",
        "Одышка",
        "Боль в груди",
        "Мушки перед глазами",
        "Тревога",
        "Плохой сон",
        "Отёки"
    ]
}

// MARK: - Категория давления

/// Категории по классификации офисного АД (клинические рекомендации
/// «Артериальная гипертензия у взрослых», 2024). Справочная подсказка, не диагноз.
enum BPCategory: Int, CaseIterable {
    case low
    case optimal
    case normal
    case highNormal
    case grade1
    case grade2
    case grade3

    init(systolic: Int, diastolic: Int) {
        if systolic >= 180 || diastolic >= 110 {
            self = .grade3
        } else if systolic >= 160 || diastolic >= 100 {
            self = .grade2
        } else if systolic >= 140 || diastolic >= 90 {
            self = .grade1
        } else if systolic >= 130 || diastolic >= 85 {
            self = .highNormal
        } else if systolic >= 120 || diastolic >= 80 {
            self = .normal
        } else if systolic < 90 || diastolic < 60 {
            self = .low
        } else {
            self = .optimal
        }
    }

    var title: String {
        switch self {
        case .low: return "Пониженное"
        case .optimal: return "Оптимальное"
        case .normal: return "Нормальное"
        case .highNormal: return "Высокое нормальное"
        case .grade1: return "Повышенное (1-я степень)"
        case .grade2: return "Высокое (2-я степень)"
        case .grade3: return "Очень высокое (3-я степень)"
        }
    }
}

// MARK: - Погода

struct WeatherSnapshot: Codable, Hashable {
    /// Мокрый снег: в кодах WMO для прогнозов такого нет, используем собственный.
    static let sleetCode = 1000

    /// Температура воздуха, °C
    var temperature: Double
    /// Атмосферное давление на уровне местности, мм рт. ст.
    var pressureMmHg: Double
    /// Изменение давления за предыдущие 24 часа, мм рт. ст.
    var pressureChange24h: Double?
    /// Относительная влажность, %
    var humidity: Double?
    /// Скорость ветра, м/с
    var windSpeed: Double?
    /// Код погоды WMO
    var weatherCode: Int?
    /// Название места
    var place: String?

    var conditionTitle: String? {
        guard let code = weatherCode else { return nil }
        switch code {
        case 0: return "ясно"
        case 1: return "малооблачно"
        case 2: return "переменная облачность"
        case 3: return "пасмурно"
        case 45, 48: return "туман"
        case 51, 53, 55: return "морось"
        case 56, 57: return "ледяная морось"
        case 61, 63, 65: return "дождь"
        case 66, 67: return "ледяной дождь"
        case 71, 73, 75, 77: return "снег"
        case 80, 81, 82: return "ливень"
        case 85, 86: return "снегопад"
        case 95: return "гроза"
        case 96, 99: return "гроза с градом"
        case WeatherSnapshot.sleetCode: return "мокрый снег"
        default: return nil
        }
    }

    var symbolName: String {
        guard let code = weatherCode else { return "cloud.fill" }
        switch code {
        case 0, 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        case WeatherSnapshot.sleetCode: return "cloud.sleet.fill"
        default: return "cloud.fill"
        }
    }

    var temperatureTitle: String {
        let rounded = Int(temperature.rounded())
        if rounded > 0 { return "+\(rounded)°" }
        return "\(rounded)°"
    }

    var pressureTitle: String { "\(Int(pressureMmHg.rounded())) мм рт. ст." }

    var pressureChangeTitle: String? {
        guard let change = pressureChange24h else { return nil }
        let rounded = Int(change.rounded())
        if rounded == 0 { return "за сутки без изменений" }
        return rounded > 0 ? "за сутки +\(rounded)" : "за сутки −\(abs(rounded))"
    }

    /// Короткая строка для списка и отчётов.
    var summary: String {
        var parts: [String] = [temperatureTitle, pressureTitle]
        if let humidity { parts.append("влажность \(Int(humidity.rounded()))%") }
        if let condition = conditionTitle { parts.append(condition) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Лекарства

struct TakenMedication: Codable, Hashable, Identifiable {
    var name: String
    var dose: String

    var id: String { name + "|" + dose }

    var title: String { dose.isEmpty ? name : "\(name) \(dose)" }
}

struct Medication: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var dose: String = ""
    var note: String = ""
    var times: [TimeOfDay] = []
    var remindersEnabled: Bool = true

    var taken: TakenMedication { TakenMedication(name: name, dose: dose) }

    var title: String { dose.isEmpty ? name : "\(name) \(dose)" }

    enum CodingKeys: String, CodingKey {
        case id, name, dose, note, times, remindersEnabled
    }
}

extension Medication {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        dose = try c.decodeIfPresent(String.self, forKey: .dose) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        times = try c.decodeIfPresent([TimeOfDay].self, forKey: .times) ?? []
        remindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? true
    }
}

/// Отметка о фактическом приёме лекарства.
struct Intake: Identifiable, Codable, Hashable {
    var id = UUID()
    var medicationID: UUID?
    var name: String
    var dose: String
    var date: Date
    /// Плановое время, к которому относится приём (если приём по расписанию).
    var slot: TimeOfDay?

    var taken: TakenMedication { TakenMedication(name: name, dose: dose) }
}

// MARK: - Напоминание о замере

struct BPReminder: Identifiable, Codable, Hashable {
    var id = UUID()
    var time: TimeOfDay
    var enabled: Bool = true
}

// MARK: - Запись дневника

struct BPEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var systolic: Int
    var diastolic: Int
    var pulse: Int?
    var wellbeing: Wellbeing?
    var symptoms: [String] = []
    var medications: [TakenMedication] = []
    var weather: WeatherSnapshot?
    var note: String = ""
    /// Идентификатор образца в «Здоровье», если запись импортирована оттуда.
    var healthUUID: UUID?
    /// Название приложения или прибора, из которого пришёл замер.
    var healthSourceName: String?
    /// Запись уже выгружена в «Здоровье».
    var healthSynced: Bool = false

    var isImported: Bool { healthUUID != nil }

    var category: BPCategory { BPCategory(systolic: systolic, diastolic: diastolic) }

    var pressureTitle: String { "\(systolic)/\(diastolic)" }

    enum CodingKeys: String, CodingKey {
        case id, date, systolic, diastolic, pulse, wellbeing, symptoms, medications
        case weather, note, healthUUID, healthSourceName, healthSynced
    }
}

extension BPEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        systolic = try c.decode(Int.self, forKey: .systolic)
        diastolic = try c.decode(Int.self, forKey: .diastolic)
        pulse = try c.decodeIfPresent(Int.self, forKey: .pulse)
        wellbeing = try c.decodeIfPresent(Wellbeing.self, forKey: .wellbeing)
        symptoms = try c.decodeIfPresent([String].self, forKey: .symptoms) ?? []
        medications = try c.decodeIfPresent([TakenMedication].self, forKey: .medications) ?? []
        weather = try c.decodeIfPresent(WeatherSnapshot.self, forKey: .weather)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        healthUUID = try c.decodeIfPresent(UUID.self, forKey: .healthUUID)
        healthSourceName = try c.decodeIfPresent(String.self, forKey: .healthSourceName)
        healthSynced = try c.decodeIfPresent(Bool.self, forKey: .healthSynced) ?? false
    }
}

// MARK: - Настройки

struct ManualCity: Codable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double
}

enum WeatherSource: String, Codable, CaseIterable, Identifiable {
    case location
    case city

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: return "По геопозиции"
        case .city: return "Выбранный город"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var onboardingDone: Bool = false
    var healthSyncEnabled: Bool = false
    var weatherEnabled: Bool = true
    var weatherSource: WeatherSource = .location
    var manualCity: ManualCity?
    var snoozeMinutes: Int = 15
    var ai = AISettings()

    enum CodingKeys: String, CodingKey {
        case onboardingDone, healthSyncEnabled, weatherEnabled, weatherSource, manualCity, snoozeMinutes, ai
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        healthSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .healthSyncEnabled) ?? false
        weatherEnabled = try c.decodeIfPresent(Bool.self, forKey: .weatherEnabled) ?? true
        weatherSource = try c.decodeIfPresent(WeatherSource.self, forKey: .weatherSource) ?? .location
        manualCity = try c.decodeIfPresent(ManualCity.self, forKey: .manualCity)
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 15
        ai = (try? c.decodeIfPresent(AISettings.self, forKey: .ai)) ?? AISettings()
    }
}

// MARK: - Корневой контейнер данных

struct DiaryData: Codable {
    var version: Int = 1
    var entries: [BPEntry] = []
    var medications: [Medication] = []
    var intakes: [Intake] = []
    var bpReminders: [BPReminder] = []
    var settings = AppSettings()
    /// Замеры из «Здоровья», которые пользователь удалил из дневника (чтобы не импортировать повторно).
    var ignoredHealthUUIDs: [UUID] = []

    enum CodingKeys: String, CodingKey {
        case version, entries, medications, intakes, bpReminders, settings, ignoredHealthUUIDs
    }
}

extension DiaryData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([BPEntry].self, forKey: .entries) ?? []
        medications = try c.decodeIfPresent([Medication].self, forKey: .medications) ?? []
        intakes = try c.decodeIfPresent([Intake].self, forKey: .intakes) ?? []
        bpReminders = try c.decodeIfPresent([BPReminder].self, forKey: .bpReminders) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        ignoredHealthUUIDs = try c.decodeIfPresent([UUID].self, forKey: .ignoredHealthUUIDs) ?? []
    }

    /// Данные первого запуска: напоминания о замере утром и вечером.
    static var initial: DiaryData {
        var data = DiaryData()
        data.bpReminders = [
            BPReminder(time: TimeOfDay(hour: 8, minute: 0)),
            BPReminder(time: TimeOfDay(hour: 20, minute: 0))
        ]
        return data
    }
}
