import SwiftUI

enum AppTab: Hashable {
    case diary
    case medications
    case stats
    case settings
}

/// Навигация верхнего уровня: выбранная вкладка и открытие формы нового замера.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var tab: AppTab = .diary
    @Published var showNewEntry: Bool = false

    private init() {}

    func openNewEntry() {
        tab = .diary
        showNewEntry = true
    }
}
