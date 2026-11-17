import SwiftUI
import UIKit

/// Вкладка «Настройки»: напоминания о замере, «Здоровье», погода, отчёты.
struct SettingsView: View {
    @EnvironmentObject private var store: DiaryStore
    @Environment(\.openURL) private var openURL

    enum ReportPeriod: Int, CaseIterable, Identifiable {
        case month = 30
        case quarter = 90
        case all = 0

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .month: return "30 дней"
            case .quarter: return "90 дней"
            case .all: return "Всё время"
            }
        }

        var days: Int? { self == .all ? nil : rawValue }
    }

    @State private var reportPeriod: ReportPeriod = .month
    @State private var sharedFile: SharedFile?
    @State private var exportError: String?
    @State private var isSyncing = false
    @State private var weatherCheckLines: [String] = []
    @State private var isCheckingWeather = false

    var body: some View {
        NavigationStack {
            List {
                if store.notificationsDenied {
                    Section {
                        NotificationsDeniedRow()
                    }
                }
                remindersSection
                aiSection
                healthSection
                weatherSection
                reportSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Настройки")
            .sheet(item: $sharedFile) { file in
                ActivityView(items: [file.url])
            }
        }
    }

    // MARK: - Напоминания о замере

    private var remindersSection: some View {
        Section {
            ForEach(store.bpReminders) { reminder in
                HStack {
                    DatePicker(
                        "Время замера",
                        selection: timeBinding(for: reminder),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Spacer()
                    Toggle("Напоминать", isOn: enabledBinding(for: reminder))
                        .labelsHidden()
                }
            }
            .onDelete { offsets in
                store.deleteReminders(at: offsets)
            }

            Button {
                store.addReminder()
            } label: {
                Label("Добавить время", systemImage: "plus.circle.fill")
            }

            Picker("Кнопка «Напомнить позже»", selection: snoozeBinding) {
                Text("через 10 минут").tag(10)
                Text("через 15 минут").tag(15)
                Text("через 30 минут").tag(30)
                Text("через час").tag(60)
            }
        } header: {
            Text("Напоминания о замере давления")
        } footer: {
            Text("Уведомление приходит каждый день в указанное время. Чтобы удалить время, смахните строку влево. Напоминания о приёме лекарств настраиваются на вкладке «Лекарства».")
        }
    }

    private func timeBinding(for reminder: BPReminder) -> Binding<Date> {
        Binding(
            get: { reminder.time.date() },
            set: { newValue in
                store.updateReminder(id: reminder.id, time: TimeOfDay(date: newValue))
            }
        )
    }

    private func enabledBinding(for reminder: BPReminder) -> Binding<Bool> {
        Binding(
            get: { reminder.enabled },
            set: { newValue in
                store.updateReminder(id: reminder.id, enabled: newValue)
            }
        )
    }

    private var snoozeBinding: Binding<Int> {
        Binding(
            get: { store.settings.snoozeMinutes },
            set: { newValue in
                store.updateSettings { $0.snoozeMinutes = newValue }
            }
        )
    }

    // MARK: - ИИ-помощник

    private var aiSection: some View {
        Section {
            NavigationLink {
                AIServicesView()
            } label: {
                LabeledContent("ИИ-помощник") {
                    Text(verbatim: store.settings.ai.provider.title)
                }
            }
        } footer: {
            Text("Выбор сервиса для анализа дневника и справок о лекарствах: встроенная модель или облачный сервис.")
        }
    }

    // MARK: - «Здоровье»

    private var healthSection: some View {
        Section {
            if store.healthAvailable {
                Toggle("Обмен с приложением «Здоровье»", isOn: healthBinding)
                    .disabled(store.healthEntitlementMissing)

                if store.settings.healthSyncEnabled {
                    Button {
                        isSyncing = true
                        Task {
                            await store.syncWithHealth()
                            isSyncing = false
                        }
                    } label: {
                        HStack {
                            Label("Синхронизировать сейчас", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing)
                }
            } else {
                Text("На этом устройстве приложение «Здоровье» недоступно.")
                    .foregroundStyle(.secondary)
            }

            if let message = store.healthMessage {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Здоровье")
        } footer: {
            Text("Замеры из дневника записываются в «Здоровье» (давление и пульс), а замеры из других приложений и тонометров за последние 90 дней появляются в дневнике. Лекарства, самочувствие и погода хранятся только в дневнике.")
        }
    }

    private var healthBinding: Binding<Bool> {
        Binding(
            get: { store.settings.healthSyncEnabled },
            set: { newValue in
                Task { await store.setHealthSync(newValue) }
            }
        )
    }

    // MARK: - Погода

    private var weatherSection: some View {
        Section {
            Toggle("Добавлять погоду к замеру", isOn: weatherEnabledBinding)

            if store.settings.weatherEnabled {
                Picker("Место", selection: weatherSourceBinding) {
                    ForEach(WeatherSource.allCases) { source in
                        Text(verbatim: source.title).tag(source)
                    }
                }

                if store.settings.weatherSource == .city {
                    NavigationLink {
                        CitySearchView()
                    } label: {
                        LabeledContent("Город") {
                            Text(verbatim: store.settings.manualCity?.name ?? "Не выбран")
                        }
                    }
                }

                Button {
                    isCheckingWeather = true
                    weatherCheckLines = []
                    Task {
                        weatherCheckLines = await store.checkWeatherSources()
                        isCheckingWeather = false
                    }
                } label: {
                    HStack {
                        Label("Проверить источники погоды", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if isCheckingWeather {
                            ProgressView()
                        }
                    }
                }
                .disabled(isCheckingWeather)

                ForEach(weatherCheckLines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Погода")
        } footer: {
            Text("Для погоды по геопозиции используется примерное местоположение (с точностью около километра). Источники: Open-Meteo.com, а если он недоступен — MET Norway (api.met.no). Давление указывается на уровне местности, как в сводках погоды.")
        }
    }

    private var weatherEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.weatherEnabled },
            set: { newValue in
                store.updateSettings { $0.weatherEnabled = newValue }
            }
        )
    }

    private var weatherSourceBinding: Binding<WeatherSource> {
        Binding(
            get: { store.settings.weatherSource },
            set: { newValue in
                store.updateSettings { $0.weatherSource = newValue }
                if newValue == .location {
                    LocationProvider.shared.requestPermission()
                }
            }
        )
    }

    // MARK: - Отчёты

    private var reportSection: some View {
        Section {
            Picker("Период", selection: $reportPeriod) {
                ForEach(ReportPeriod.allCases) { item in
                    Text(verbatim: item.title).tag(item)
                }
            }
            Button {
                exportPDF()
            } label: {
                Label("Отчёт для врача (PDF)", systemImage: "doc.richtext")
            }
            Button {
                exportCSV()
            } label: {
                Label("Таблица для Excel (CSV)", systemImage: "tablecells")
            }
            if let exportError {
                Text(verbatim: exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Отчёты")
        } footer: {
            Text("Файл можно распечатать, отправить врачу или сохранить в «Файлы».")
        }
    }

    private func exportPDF() {
        do {
            let entries = store.entries(inLast: reportPeriod.days)
            let url = try ExportService.writePDF(entries: entries, periodTitle: reportPeriod.title.lowercased())
            exportError = nil
            sharedFile = SharedFile(url: url)
        } catch {
            exportError = "Не удалось создать отчёт: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        do {
            let entries = store.entries(inLast: reportPeriod.days)
            let url = try ExportService.writeCSV(entries: entries)
            exportError = nil
            sharedFile = SharedFile(url: url)
        } catch {
            exportError = "Не удалось создать таблицу: \(error.localizedDescription)"
        }
    }

    // MARK: - О приложении

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Версия") {
                Text(verbatim: appVersion)
            }
            Button("Погода: Open-Meteo.com") {
                if let url = URL(string: "https://open-meteo.com/") {
                    openURL(url)
                }
            }
            Button("Погода: MET Norway") {
                if let url = URL(string: "https://api.met.no/") {
                    openURL(url)
                }
            }
        } header: {
            Text("О приложении")
        } footer: {
            Text("Приложение — личный дневник. Оно не является медицинским изделием, не измеряет давление, не ставит диагнозов и не заменяет консультацию врача. Категории давления показаны для справки по общепринятой классификации. Дневник хранится только на этом iPhone и в приложении «Здоровье».")
        }
    }
}

/// Поиск и выбор города для погоды.
struct CitySearchView: View {
    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [CityResult] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Название города", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                    if isSearching {
                        ProgressView()
                    }
                }
                Button("Найти") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
            }

            if let message {
                Section {
                    Text(verbatim: message)
                        .foregroundStyle(.secondary)
                }
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { city in
                        Button {
                            select(city)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: city.name)
                                    .foregroundStyle(.primary)
                                if !city.subtitle.isEmpty {
                                    Text(verbatim: city.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Выберите город")
                }
            }
        }
        .navigationTitle("Город")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() {
        let text = query
        isSearching = true
        message = nil
        Task {
            do {
                let found = try await LocationProvider.shared.searchCity(text)
                results = found
                message = found.isEmpty ? "Ничего не найдено. Проверьте название." : nil
            } catch {
                results = []
                message = "Не удалось выполнить поиск: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func select(_ city: CityResult) {
        store.updateSettings { settings in
            settings.manualCity = ManualCity(name: city.name, latitude: city.latitude, longitude: city.longitude)
            settings.weatherSource = .city
        }
        dismiss()
    }
}
