import SwiftUI

/// Форма нового замера и редактирования существующего.
struct EntryEditorView: View {
    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case systolic
        case diastolic
        case pulse
        case customMedication
        case note
    }

    private enum WeatherState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private let original: BPEntry?

    @State private var date: Date
    @State private var systolicText: String
    @State private var diastolicText: String
    @State private var pulseText: String
    @State private var wellbeing: Wellbeing?
    @State private var symptoms: Set<String>
    @State private var takenMedications: [TakenMedication]
    @State private var customMedication: String = ""
    @State private var weather: WeatherSnapshot?
    @State private var weatherState: WeatherState = .idle
    @State private var note: String
    @State private var didPrepare = false

    @FocusState private var focus: Field?

    init(entry: BPEntry?) {
        original = entry
        _date = State(initialValue: entry?.date ?? Date())
        _systolicText = State(initialValue: entry.map { String($0.systolic) } ?? "")
        _diastolicText = State(initialValue: entry.map { String($0.diastolic) } ?? "")
        _pulseText = State(initialValue: entry?.pulse.map { String($0) } ?? "")
        _wellbeing = State(initialValue: entry?.wellbeing)
        _symptoms = State(initialValue: Set(entry?.symptoms ?? []))
        _takenMedications = State(initialValue: entry?.medications ?? [])
        _weather = State(initialValue: entry?.weather)
        _note = State(initialValue: entry?.note ?? "")
    }

    private var isNew: Bool { original == nil }
    private var isImported: Bool { original?.isImported ?? false }

    // MARK: - Проверка значений

    private var systolic: Int? { Int(systolicText) }
    private var diastolic: Int? { Int(diastolicText) }
    private var pulse: Int? { pulseText.isEmpty ? nil : Int(pulseText) }

    private var category: BPCategory? {
        guard validationMessage == nil, let systolic, let diastolic else { return nil }
        return BPCategory(systolic: systolic, diastolic: diastolic)
    }

    private var validationMessage: String? {
        guard let systolic, let diastolic else { return nil }
        if systolic < 50 || systolic > 300 { return "Верхнее давление должно быть от 50 до 300." }
        if diastolic < 30 || diastolic > 200 { return "Нижнее давление должно быть от 30 до 200." }
        if diastolic >= systolic { return "Нижнее давление должно быть меньше верхнего." }
        if !pulseText.isEmpty {
            guard let pulse, pulse >= 30, pulse <= 250 else { return "Пульс должен быть от 30 до 250." }
        }
        return nil
    }

    private var canSave: Bool {
        systolic != nil && diastolic != nil && validationMessage == nil
    }

    private var needsUrgentHint: Bool {
        guard canSave, let systolic, let diastolic else { return false }
        return systolic >= 180 || diastolic >= 120
    }

    // MARK: - Экран

    var body: some View {
        NavigationStack {
            Form {
                pressureSection
                dateSection
                wellbeingSection
                medicationsSection
                weatherSection
                noteSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "Новый замер" : "Замер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(keyboardButtonTitle) { advanceFocus() }
                }
            }
            .task {
                await prepare()
            }
        }
    }

    // MARK: - Давление

    private var pressureSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                numberField(title: "Верхнее", placeholder: "120", text: $systolicText, field: .systolic)
                    .disabled(isImported)
                Text(verbatim: "/")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                numberField(title: "Нижнее", placeholder: "80", text: $diastolicText, field: .diastolic)
                    .disabled(isImported)
                Divider()
                numberField(title: "Пульс", placeholder: "—", text: $pulseText, field: .pulse)
                    .disabled(isImported)
            }
            .padding(.vertical, 4)

            if let category {
                HStack(spacing: 8) {
                    Circle()
                        .fill(category.color)
                        .frame(width: 10, height: 10)
                    Text(verbatim: category.title)
                        .font(.subheadline)
                }
            }
            if let message = validationMessage {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if needsUrgentHint {
                Label {
                    Text("Очень высокое давление. Если самочувствие плохое, обратитесь за медицинской помощью: 103 или 112.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Давление и пульс")
        } footer: {
            if isImported {
                Text("Замер получен из «Здоровья», поэтому цифры изменить нельзя. Остальное можно дополнить.")
            } else {
                Text("мм рт. ст. и удары в минуту. Пульс можно не указывать.")
            }
        }
    }

    private func numberField(title: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(spacing: 2) {
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .focused($focus, equals: field)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let digits = newValue.filter { $0.isASCII && $0.isNumber }
                    let trimmed = String(digits.prefix(3))
                    if trimmed != newValue {
                        text.wrappedValue = trimmed
                    }
                    if field == .systolic, trimmed.count == 3, focus == .systolic {
                        focus = .diastolic
                    }
                }
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var keyboardButtonTitle: String {
        switch focus {
        case .systolic, .diastolic: return "Далее"
        default: return "Готово"
        }
    }

    private func advanceFocus() {
        switch focus {
        case .systolic: focus = .diastolic
        case .diastolic: focus = .pulse
        default: focus = nil
        }
    }

    // MARK: - Дата

    private var dateSection: some View {
        Section {
            DatePicker(
                "Дата и время",
                selection: $date,
                in: ...Date().addingTimeInterval(300),
                displayedComponents: [.date, .hourAndMinute]
            )
            .disabled(isImported)
        }
    }

    // MARK: - Самочувствие

    private var wellbeingSection: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(Array(Wellbeing.allCases.reversed())) { level in
                    Button {
                        wellbeing = (wellbeing == level) ? nil : level
                    } label: {
                        WellbeingOptionLabel(level: level, isSelected: wellbeing == level)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: level.title))
                }
            }

            LazyVGrid(columns: symptomColumns, alignment: .leading, spacing: 8) {
                ForEach(SymptomCatalog.all, id: \.self) { symptom in
                    Button {
                        toggle(symptom: symptom)
                    } label: {
                        SymptomChipLabel(title: symptom, isSelected: symptoms.contains(symptom))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Самочувствие")
        } footer: {
            Text("Отметьте общее состояние и симптомы, если они есть.")
        }
    }

    private var symptomColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 130), spacing: 8)]
    }

    private func toggle(symptom: String) {
        if symptoms.contains(symptom) {
            symptoms.remove(symptom)
        } else {
            symptoms.insert(symptom)
        }
    }

    // MARK: - Лекарства

    private var extraMedications: [TakenMedication] {
        let known = Set(store.medications.map { $0.taken })
        return takenMedications.filter { !known.contains($0) }
    }

    private var medicationsSection: some View {
        Section {
            ForEach(store.medications) { medication in
                Button {
                    toggle(medication: medication.taken)
                } label: {
                    medicationRow(medication.taken, selected: takenMedications.contains(medication.taken))
                }
                .buttonStyle(.plain)
            }

            ForEach(extraMedications) { item in
                Button {
                    toggle(medication: item)
                } label: {
                    medicationRow(item, selected: true)
                }
                .buttonStyle(.plain)
            }

            HStack {
                TextField("Другое лекарство", text: $customMedication)
                    .focused($focus, equals: .customMedication)
                    .submitLabel(.done)
                    .onSubmit { addCustomMedication() }
                Button("Добавить") { addCustomMedication() }
                    .buttonStyle(.borderless)
                    .disabled(customMedication.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Принятые лекарства")
        } footer: {
            if store.medications.isEmpty {
                Text("Постоянные лекарства и напоминания о приёме добавляются на вкладке «Лекарства».")
            } else {
                Text("Отметьте, что было принято перед замером.")
            }
        }
    }

    private func medicationRow(_ item: TakenMedication, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                if !item.dose.isEmpty {
                    Text(verbatim: item.dose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func toggle(medication: TakenMedication) {
        if let index = takenMedications.firstIndex(of: medication) {
            takenMedications.remove(at: index)
        } else {
            takenMedications.append(medication)
        }
    }

    private func addCustomMedication() {
        let name = customMedication.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let item = TakenMedication(name: name, dose: "")
        if !takenMedications.contains(item) {
            takenMedications.append(item)
        }
        customMedication = ""
    }

    // MARK: - Погода

    @ViewBuilder
    private var weatherSection: some View {
        if store.settings.weatherEnabled {
            Section {
                if let weather {
                    WeatherSummaryView(weather: weather)
                }
                switch weatherState {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Загружаю погоду…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(weather == nil ? "Загрузить погоду" : "Обновить для выбранного времени") {
                    Task { await loadWeather() }
                }
                .disabled(weatherState == .loading)
                if weather != nil {
                    Button("Убрать погоду из записи", role: .destructive) {
                        weather = nil
                        weatherState = .idle
                    }
                }
            } header: {
                Text("Погода")
            } footer: {
                Text("Температура, атмосферное давление и влажность на момент замера. Данные: Open-Meteo.com.")
            }
        }
    }

    private func loadWeather() async {
        weatherState = .loading
        do {
            weather = try await store.loadWeather(for: date)
            weatherState = .idle
        } catch {
            weatherState = .failed("Не удалось получить погоду: \(error.localizedDescription)")
        }
    }

    // MARK: - Заметка

    private var noteSection: some View {
        Section {
            TextField("Например: после прогулки, перед сном", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .focused($focus, equals: .note)
        } header: {
            Text("Заметка")
        }
    }

    // MARK: - Действия

    /// Подготовка новой записи: отмечаем лекарства, принятые сегодня, и подгружаем погоду.
    private func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        guard isNew else { return }

        var seen = Set<TakenMedication>()
        var prefilled: [TakenMedication] = []
        for intake in store.intakes(on: Date()) {
            let item = intake.taken
            if !seen.contains(item) {
                seen.insert(item)
                prefilled.append(item)
            }
        }
        if takenMedications.isEmpty {
            takenMedications = prefilled
        }

        focus = .systolic

        if store.settings.weatherEnabled {
            await loadWeather()
        }
    }

    private func save() {
        guard canSave, let systolic, let diastolic else { return }
        var entry = original ?? BPEntry(systolic: systolic, diastolic: diastolic)
        entry.date = date
        entry.systolic = systolic
        entry.diastolic = diastolic
        entry.pulse = pulse
        entry.wellbeing = wellbeing
        entry.symptoms = SymptomCatalog.all.filter { symptoms.contains($0) }
        entry.medications = takenMedications
        entry.weather = weather
        entry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(entry: entry)
        dismiss()
    }
}

/// Кнопка выбора общего самочувствия.
private struct WellbeingOptionLabel: View {
    let level: Wellbeing
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: level.emoji)
                .font(.system(size: 30))
            Text(verbatim: level.title)
                .font(.system(size: 10))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(background)
        .contentShape(Rectangle())
    }

    private var background: some View {
        let fill: Color = isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        return RoundedRectangle(cornerRadius: 10).fill(fill)
    }
}

/// Метка-«таблетка» для симптома.
private struct SymptomChipLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(textColor)
            .background(background)
            .contentShape(Capsule())
    }

    private var textColor: Color {
        isSelected ? Color.white : Color.primary
    }

    private var background: some View {
        let fill: Color = isSelected ? Color.accentColor : Color.secondary.opacity(0.15)
        return Capsule().fill(fill)
    }
}
