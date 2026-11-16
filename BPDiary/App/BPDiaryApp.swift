import SwiftUI

@main
struct BPDiaryApp: App {
    @StateObject private var store = DiaryStore.shared
    @StateObject private var router = AppRouter.shared

    init() {
        // Делегат уведомлений нужно назначить до завершения запуска,
        // иначе нажатия на кнопки уведомлений не дойдут до приложения.
        NotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}
