import Foundation
import SwiftUI

/// Единое хранилище дневника. Данные лежат в одном JSON-файле в папке приложения на устройстве.
@MainActor
final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    @Published private(set) var data: DiaryData {
        didSet { persist() }
    }

    /// Последняя ошибка обмена со «Здоровьем» (для показа в настройках).
    @Published var healthMessage: String?
    /// Уведомления запрещены в системных настройках.
    @Published var notificationsDenied: Bool = false

    private let fileURL: URL
    private let health = HealthKitService.shared

    private init() {
        let fileManager = FileManager.default
        let directory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let url = directory.appendingPathComponent("diary.json")
        fileURL = url

        if let raw = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(DiaryData.self, from: raw) {
                data = decoded
            } else {
                // Файл не читается: сохраняем копию, чтобы не потерять данные, и начинаем с чистого листа.
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = directory.appendingPathComponent("diary-damaged-\(stamp).json")
                try? raw.write(to: backup, options: [.atomic])
                data = DiaryData.initial
            }
        } else {
            data = DiaryData.initial
        }
    }

    private func persist() {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            print("Не удалось сохранить дневник: \(error)")
        }
    }

    // MARK: - Чтение

    var entries: [BPEntry] { data.entries }
    var medications: [Medication] { data.medications }
    var intakes: [Intake] { data.intakes }
    var bpReminders: [BPReminder] { data.bpReminders }
    var settings: AppSettings { data.settings }

    func entries(inLast days: Int?) -> [BPEntry] {
        guard let days else { return data.entries }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        return data.entries.filter { $0.date >= start }
    }

    // MARK: - Настройки

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = data.settings
        change(&copy)
        data.settings = copy
    }

    // MARK: - Записи

    /// Добавляет новую запись или заменяет существующую с тем же идентификатором.
    func save(entry: BPEntry) {
        var updated = entry
        let previous = data.entries.first { $0.id == entry.id }
        var measurementChanged = true
        if let previous {
            measurementChanged = previous.systolic != entry.systolic
                || previous.diastolic != entry.diastolic
                || previous.pulse != entry.pulse
                || previous.date != entry.date
        }
        if measurementChanged { updated.healthSynced = false }

        var list = data.entries.filter { $0.id != entry.id }
        list.append(updated)
        list.sort { $0.date > $1.date }
        data.entries = list

        if data.settings.healthSyncEnabled, !updated.isImported, measurementChanged {
            let id = updated.id
            Task {
                await self.runHealthJob {
                    await self.pushToHealth(entryID: id)
                }
            }
        }
    }

    func delete(entry: BPEntry) {
        var copy = data
        copy.entries.removeAll { $0.id == entry.id }
        if let uuid = entry.healthUUID, !copy.ignoredHealthUUIDs.contains(uuid) {
            copy.ignoredHealthUUIDs.append(uuid)
        }
        data = copy

        if !entry.isImported, entry.healthSynced {
            let id = entry.id
            Task {
                await self.runHealthJob {
                    await self.removeFromHealth(entryID: id)
                }
            }
        }
    }

    private func markSynced(_ id: UUID) {
        guard let index = data.entries.firstIndex(where: { $0.id == id }) else { return }
        var list = data.entries
        list[index].healthSynced = true
        data.entries = list
    }

    // MARK: - «Здоровье»

    var healthAvailable: Bool { health.isAvailable }

    /// Хвост очереди операций со «Здоровьем»: они выполняются строго по одной,
    /// чтобы один и тот же замер не записался или не импортировался дважды.
    private var healthTail: Task<Void, Never>?

    private func runHealthJob(_ job: @escaping @MainActor () async -> Void) async {
        let previous = healthTail
        let task = Task { @MainActor in
            if let previous {
                await previous.value
            }
            await job()
        }
        healthTail = task
        await task.value
    }

    private func pushToHealth(entryID: UUID) async {
        guard let entry = data.entries.first(where: { $0.id == entryID }) else { return }
        if entry.healthSynced { return }
        do {
            // Сначала убираем прежнюю версию этого замера, чтобы в «Здоровье» не было дублей.
            try await health.delete(entryID: entryID)
            try await health.save(entry: entry)
            markSynced(entryID)
        } catch {
            healthMessage = "Не удалось записать замер в «Здоровье»: \(error.localizedDescription)"
        }
    }

    private func removeFromHealth(entryID: UUID) async {
        do {
            try await health.delete(entryID: entryID)
        } catch {
            healthMessage = "Не удалось удалить замер из «Здоровья»: \(error.localizedDescription)"
        }
    }

    /// Включает или выключает обмен со «Здоровьем».
    func setHealthSync(_ enabled: Bool) async {
        guard enabled else {
            updateSettings { $0.healthSyncEnabled = false }
            healthMessage = nil
            return
        }
        guard health.isAvailable else {
            healthMessage = "На этом устройстве приложение «Здоровье» недоступно."
            return
        }
        do {
            try await health.requestAuthorization()
            updateSettings { $0.healthSyncEnabled = true }
            if health.canWriteBloodPressure {
                healthMessage = nil
            } else {
                healthMessage = "Запись давления не разрешена. Откройте «Здоровье», нажмите на свой профиль, выберите «Приложения» и включите доступ для этого приложения."
            }
            await syncWithHealth()
        } catch {
            healthMessage = "Не удалось подключить «Здоровье»: \(error.localizedDescription)"
        }
    }

    /// Выгружает несинхронизированные записи и забирает новые замеры из «Здоровья».
    func syncWithHealth() async {
        guard data.settings.healthSyncEnabled, health.isAvailable else { return }
        await runHealthJob {
            await self.performSync()
        }
    }

    private func performSync() async {
        if health.canWriteBloodPressure {
            let pendingIDs = data.entries
                .filter { !$0.isImported && !$0.healthSynced }
                .map { $0.id }
            for id in pendingIDs {
                guard let entry = data.entries.first(where: { $0.id == id }), !entry.healthSynced else { continue }
                do {
                    // На случай, если прошлая запись оборвалась на полпути.
                    try await health.delete(entryID: id)
                    try await health.save(entry: entry)
                    markSynced(id)
                } catch {
                    healthMessage = "Не удалось записать замер в «Здоровье»: \(error.localizedDescription)"
                    break
                }
            }
        }
        await importFromHealth()
    }

    private func importFromHealth(days: Int = 90) async {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        do {
            let readings = try await health.readExternalReadings(since: since)
            var known = Set(data.entries.compactMap { $0.healthUUID })
            known.formUnion(data.ignoredHealthUUIDs)
            let fresh = readings.filter { !known.contains($0.uuid) }
            guard !fresh.isEmpty else { return }

            var list = data.entries
            for reading in fresh {
                var entry = BPEntry(systolic: reading.systolic, diastolic: reading.diastolic)
                entry.date = reading.date
                entry.pulse = reading.pulse
                entry.healthUUID = reading.uuid
                entry.healthSourceName = reading.sourceName
                entry.healthSynced = true
                list.append(entry)
            }
            list.sort { $0.date > $1.date }
            data.entries = list
        } catch {
            healthMessage = "Не удалось прочитать замеры из «Здоровья»: \(error.localizedDescription)"
        }
    }

    // MARK: - Лекарства

    func save(medication: Medication) {
        var list = data.medications
        if let index = list.firstIndex(where: { $0.id == medication.id }) {
            list[index] = medication
        } else {
            list.append(medication)
        }
        data.medications = list
        refreshNotifications(requestPermission: medication.remindersEnabled && !medication.times.isEmpty)
    }

    func delete(medication: Medication) {
        data.medications.removeAll { $0.id == medication.id }
        refreshNotifications()
    }

    // MARK: - Приёмы лекарств

    func logIntake(medicationID: UUID, slot: TimeOfDay?, date: Date = Date()) {
        guard let medication = data.medications.first(where: { $0.id == medicationID }) else { return }
        if let slot, intake(for: medication, slot: slot, on: date) != nil { return }
        let record = Intake(
            medicationID: medication.id,
            name: medication.name,
            dose: medication.dose,
            date: date,
            slot: slot
        )
        var list = data.intakes
        list.append(record)
        list.sort { $0.date > $1.date }
        data.intakes = list
    }

    func delete(intake: Intake) {
        data.intakes.removeAll { $0.id == intake.id }
    }

    func intake(for medication: Medication, slot: TimeOfDay, on day: Date) -> Intake? {
        let calendar = Calendar.current
        return data.intakes.first {
            $0.medicationID == medication.id && $0.slot == slot && calendar.isDate($0.date, inSameDayAs: day)
        }
    }

    func intakes(on day: Date) -> [Intake] {
        let calendar = Calendar.current
        return data.intakes.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    // MARK: - Напоминания о замере

    func addReminder() {
        let existing = Set(data.bpReminders.map { $0.time })
        var candidate = TimeOfDay(hour: 14, minute: 0)
        for hour in [8, 14, 20, 12, 18, 22, 7, 9, 10, 11, 13, 15, 16, 17, 19, 21] {
            let option = TimeOfDay(hour: hour, minute: 0)
            if !existing.contains(option) {
                candidate = option
                break
            }
        }
        data.bpReminders.append(BPReminder(time: candidate))
        refreshNotifications(requestPermission: true)
    }

    func updateReminder(id: UUID, time: TimeOfDay? = nil, enabled: Bool? = nil) {
        guard let index = data.bpReminders.firstIndex(where: { $0.id == id }) else { return }
        var list = data.bpReminders
        if let time { list[index].time = time }
        if let enabled { list[index].enabled = enabled }
        guard list != data.bpReminders else { return }
        data.bpReminders = list
        refreshNotifications(requestPermission: enabled == true)
    }

    func deleteReminders(at offsets: IndexSet) {
        var list = data.bpReminders
        list.remove(atOffsets: offsets)
        data.bpReminders = list
        refreshNotifications()
    }

    // MARK: - Уведомления

    /// Пересоздаёт расписание уведомлений по текущим лекарствам и напоминаниям.
    func refreshNotifications(requestPermission: Bool = false) {
        let medications = data.medications
        let reminders = data.bpReminders
        Task {
            let manager = NotificationManager.shared
            if requestPermission {
                _ = await manager.requestAuthorization()
            }
            await manager.reschedule(medications: medications, reminders: reminders)
            self.notificationsDenied = await manager.isDenied()
        }
    }

    // MARK: - Погода

    func loadWeather(for date: Date) async throws -> WeatherSnapshot {
        let settings = data.settings
        let service = WeatherService()
        if settings.weatherSource == .city {
            guard let city = settings.manualCity else { throw WeatherError.noCity }
            return try await service.fetch(
                latitude: city.latitude,
                longitude: city.longitude,
                date: date,
                place: city.name
            )
        }
        let location = try await LocationProvider.shared.currentLocation()
        let place = await LocationProvider.shared.placeName(for: location)
        return try await service.fetch(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            date: date,
            place: place
        )
    }

    // MARK: - Жизненный цикл

    /// Вызывается, когда приложение становится активным.
    func appBecameActive() {
        refreshNotifications()
        if data.settings.healthSyncEnabled {
            Task { await self.syncWithHealth() }
        }
    }
}
