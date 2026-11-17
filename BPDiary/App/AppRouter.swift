import SwiftUI

enum AppTab: Hashable {
    case diary
    case medications
    case assistant
    case stats
    case settings
}

/// Навигация верхнего уровня: выбранная вкладка и открытие формы нового замера.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var tab: AppTab = .diary
    @Published var showNewEntry: Bool = false

    private init() {
        #if DEBUG
        // Аргументы запуска для автоматических снимков экрана (только в отладочной сборке).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-demoTab"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "medications": tab = .medications
            case "assistant": tab = .assistant
            case "stats": tab = .stats
            case "settings": tab = .settings
            default: tab = .diary
            }
        }
        if arguments.contains("-demoNewEntry") {
            showNewEntry = true
        }
        #endif
    }

    func openNewEntry() {
        tab = .diary
        showNewEntry = true
    }
}
