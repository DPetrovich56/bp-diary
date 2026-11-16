import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.tab) {
            DiaryView()
                .tabItem { Label("Дневник", systemImage: "heart.text.square.fill") }
                .tag(AppTab.diary)

            MedicationsView()
                .tabItem { Label("Лекарства", systemImage: "pills.fill") }
                .tag(AppTab.medications)

            StatsView()
                .tabItem { Label("Графики", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.stats)

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $router.showNewEntry) {
            EntryEditorView(entry: nil)
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.appBecameActive()
            }
        }
        .onAppear {
            store.appBecameActive()
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !store.settings.onboardingDone },
            set: { _ in }
        )
    }
}

/// Экран первого запуска: объясняет, какие разрешения нужны и зачем.
struct OnboardingView: View {
    @EnvironmentObject private var store: DiaryStore

    @State private var notificationsRequested = false
    @State private var healthRequested = false
    @State private var locationRequested = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Дневник давления")
                            .font(.largeTitle.bold())
                        Text("Записывайте давление и пульс, отмечайте лекарства, самочувствие и погоду. Приложение напомнит о замере и приёме таблеток.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    permissionRow(
                        symbol: "bell.badge.fill",
                        title: "Напоминания",
                        text: "Уведомления о времени замера и приёма лекарств.",
                        done: notificationsRequested
                    ) {
                        notificationsRequested = true
                        store.refreshNotifications(requestPermission: true)
                    }

                    if store.healthAvailable {
                        permissionRow(
                            symbol: "heart.fill",
                            title: "Приложение «Здоровье»",
                            text: "Замеры будут сохраняться в «Здоровье», а данные тонометра оттуда — попадать в дневник.",
                            done: healthRequested
                        ) {
                            healthRequested = true
                            Task { await store.setHealthSync(true) }
                        }
                    }

                    permissionRow(
                        symbol: "cloud.sun.fill",
                        title: "Погода",
                        text: "Примерная геопозиция нужна, чтобы добавить к замеру температуру и атмосферное давление. Город можно указать и вручную в настройках.",
                        done: locationRequested
                    ) {
                        locationRequested = true
                        LocationProvider.shared.requestPermission()
                    }
                } header: {
                    Text("Что можно включить")
                } footer: {
                    Text("Всё это можно изменить позже в настройках. Данные дневника хранятся только на вашем iPhone и в приложении «Здоровье».")
                }

                Section {
                    Text("Приложение не является медицинским изделием, не измеряет давление и не заменяет консультацию врача.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    store.updateSettings { $0.onboardingDone = true }
                } label: {
                    Text("Начать")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func permissionRow(
        symbol: String,
        title: String,
        text: String,
        done: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if done {
                    Label("Запрошено", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Button("Включить", action: action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
