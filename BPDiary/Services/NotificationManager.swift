import Foundation
import UserNotifications

/// Локальные уведомления: приём лекарств и замер давления.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()

    private enum Category {
        static let medication = "MED_REMINDER"
        static let pressure = "BP_REMINDER"
    }

    private enum Action {
        static let taken = "ACTION_TAKEN"
        static let snooze = "ACTION_SNOOZE"
        static let measure = "ACTION_MEASURE"
    }

    private enum Key {
        static let kind = "kind"
        static let medicationID = "medID"
        static let slot = "slot"
    }

    private enum Kind {
        static let medication = "med"
        static let pressure = "bp"
    }

    /// Все плановые уведомления приложения начинаются с этого префикса.
    private static let scheduledPrefix = "sched."
    private static let snoozePrefix = "snooze."

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    /// Вызывается один раз при запуске приложения.
    func configure() {
        center.delegate = self

        let taken = UNNotificationAction(identifier: Action.taken, title: "Принято", options: [])
        let snooze = UNNotificationAction(identifier: Action.snooze, title: "Напомнить позже", options: [])
        let measure = UNNotificationAction(identifier: Action.measure, title: "Записать замер", options: [.foreground])

        let medication = UNNotificationCategory(
            identifier: Category.medication,
            actions: [taken, snooze],
            intentIdentifiers: [],
            options: []
        )
        let pressure = UNNotificationCategory(
            identifier: Category.pressure,
            actions: [measure, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([medication, pressure])
    }

    // MARK: - Разрешение

    func requestAuthorization() async -> Bool {
        let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return granted ?? false
    }

    func isDenied() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .denied
    }

    // MARK: - Расписание

    /// Полностью пересоздаёт ежедневные уведомления.
    func reschedule(medications: [Medication], reminders: [BPReminder]) async {
        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .map { $0.identifier }
            .filter { $0.hasPrefix(NotificationManager.scheduledPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for medication in medications where medication.remindersEnabled {
            for time in Set(medication.times) {
                let content = UNMutableNotificationContent()
                content.title = "Пора принять лекарство"
                content.body = medication.title
                content.sound = .default
                content.categoryIdentifier = Category.medication
                content.userInfo = [
                    Key.kind: Kind.medication,
                    Key.medicationID: medication.id.uuidString,
                    Key.slot: String(time.id)
                ]
                let identifier = "\(NotificationManager.scheduledPrefix)med.\(medication.id.uuidString).\(time.id)"
                await add(identifier: identifier, content: content, time: time)
            }
        }

        for time in Set(reminders.filter { $0.enabled }.map { $0.time }) {
            let content = UNMutableNotificationContent()
            content.title = "Пора измерить давление"
            content.body = "Посидите спокойно пять минут, измерьте давление и запишите результат."
            content.sound = .default
            content.categoryIdentifier = Category.pressure
            content.userInfo = [Key.kind: Kind.pressure]
            let identifier = "\(NotificationManager.scheduledPrefix)bp.\(time.id)"
            await add(identifier: identifier, content: content, time: time)
        }
    }

    private func add(identifier: String, content: UNNotificationContent, time: TimeOfDay) async {
        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            print("Не удалось запланировать уведомление: \(error)")
        }
    }

    private func snooze(title: String, body: String, category: String, userInfo: [String: String], minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo
        let interval = TimeInterval(max(1, minutes) * 60)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let identifier = NotificationManager.snoozePrefix + UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                print("Не удалось отложить уведомление: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Показываем уведомление, даже если приложение открыто.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Обработка нажатий на уведомление и его кнопки.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let actionID = response.actionIdentifier
        let title = content.title
        let body = content.body
        let category = content.categoryIdentifier

        var userInfo: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String {
                userInfo[key] = value
            }
        }

        let kind = userInfo[Key.kind]
        let medicationID = userInfo[Key.medicationID].flatMap { UUID(uuidString: $0) }
        var slot: TimeOfDay?
        if let raw = userInfo[Key.slot], let minutes = Int(raw) {
            slot = TimeOfDay(hour: minutes / 60, minute: minutes % 60)
        }

        Task { @MainActor in
            let store = DiaryStore.shared
            let router = AppRouter.shared

            switch actionID {
            case Action.taken:
                if let medicationID {
                    store.logIntake(medicationID: medicationID, slot: slot)
                }
            case Action.snooze:
                self.snooze(
                    title: title,
                    body: body,
                    category: category,
                    userInfo: userInfo,
                    minutes: store.settings.snoozeMinutes
                )
            case Action.measure:
                router.openNewEntry()
            case UNNotificationDefaultActionIdentifier:
                if kind == Kind.pressure {
                    router.openNewEntry()
                } else if kind == Kind.medication {
                    router.tab = .medications
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
