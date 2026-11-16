import SwiftUI
import UIKit

/// Вкладка «Лекарства»: приём на сегодня, список лекарств и журнал приёмов.
struct MedicationsView: View {
    @EnvironmentObject private var store: DiaryStore

    @State private var editing: Medication?
    @State private var creating = false

    private struct DoseSlot: Identifiable {
        let medication: Medication
        let time: TimeOfDay
        var id: String { "\(medication.id.uuidString)-\(time.id)" }
    }

    private var todaySlots: [DoseSlot] {
        var slots: [DoseSlot] = []
        for medication in store.medications {
            for time in Set(medication.times) {
                slots.append(DoseSlot(medication: medication, time: time))
            }
        }
        return slots.sorted { first, second in
            if first.time != second.time { return first.time < second.time }
            return first.medication.name < second.medication.name
        }
    }

    private var asNeeded: [Medication] {
        store.medications.filter { $0.times.isEmpty }
    }

    private var recentIntakes: [Intake] {
        Array(store.intakes.prefix(30))
    }

    var body: some View {
        NavigationStack {
            List {
                if store.notificationsDenied {
                    Section {
                        NotificationsDeniedRow()
                    }
                }

                if store.medications.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Лекарств пока нет")
                                .font(.headline)
                            Text("Добавьте лекарства, которые принимаете, и укажите время приёма — приложение будет напоминать о них.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Добавить лекарство") { creating = true }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    todaySection
                    asNeededSection
                    medicationsSection
                }

                journalSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Лекарства")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Label("Добавить лекарство", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { medication in
                MedicationEditorView(medication: medication)
            }
            .sheet(isPresented: $creating) {
                MedicationEditorView(medication: nil)
            }
        }
    }

    // MARK: - Сегодня

    @ViewBuilder
    private var todaySection: some View {
        if !todaySlots.isEmpty {
            Section {
                ForEach(todaySlots) { slot in
                    slotRow(slot)
                }
            } header: {
                Text("Приём сегодня")
            }
        }
    }

    private func slotRow(_ slot: DoseSlot) -> some View {
        let taken = store.intake(for: slot.medication, slot: slot.time, on: Date())
        return HStack(spacing: 12) {
            Text(verbatim: slot.time.title)
                .font(.headline)
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: slot.medication.name)
                if !slot.medication.dose.isEmpty {
                    Text(verbatim: slot.medication.dose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let taken {
                Button {
                    store.delete(intake: taken)
                } label: {
                    Label {
                        Text(verbatim: DayTitle.time(taken.date))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Принято. Нажмите, чтобы отменить отметку"))
            } else {
                Button("Принять") {
                    store.logIntake(medicationID: slot.medication.id, slot: slot.time)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - По необходимости

    @ViewBuilder
    private var asNeededSection: some View {
        if !asNeeded.isEmpty {
            Section {
                ForEach(asNeeded) { medication in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: medication.name)
                            if !medication.dose.isEmpty {
                                Text(verbatim: medication.dose)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Принять сейчас") {
                            store.logIntake(medicationID: medication.id, slot: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("По необходимости")
            }
        }
    }

    // MARK: - Список лекарств

    private var medicationsSection: some View {
        Section {
            ForEach(store.medications) { medication in
                Button {
                    editing = medication
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: medication.title)
                                .foregroundStyle(.primary)
                            Text(verbatim: scheduleTitle(medication))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Мои лекарства")
        }
    }

    private func scheduleTitle(_ medication: Medication) -> String {
        if medication.times.isEmpty { return "По необходимости" }
        let times = medication.times.sorted().map { $0.title }.joined(separator: ", ")
        return medication.remindersEnabled ? "Напоминания: \(times)" : "Без напоминаний: \(times)"
    }

    // MARK: - Журнал

    @ViewBuilder
    private var journalSection: some View {
        if !recentIntakes.isEmpty {
            Section {
                ForEach(recentIntakes) { intake in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: intake.taken.title)
                            Text(verbatim: DayTitle.dayAndTime(intake.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(intake: intake)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Журнал приёма")
            } footer: {
                Text("Показаны последние отметки. Смахните строку влево, чтобы удалить.")
            }
        }
    }
}

/// Предупреждение о том, что уведомления запрещены в системных настройках.
struct NotificationsDeniedRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Уведомления выключены")
                    .font(.headline)
            } icon: {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.orange)
            }
            Text("Напоминания не придут, пока уведомления для приложения запрещены в настройках iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

/// Форма добавления и редактирования лекарства.
struct MedicationEditorView: View {
    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    private struct EditableTime: Identifiable {
        let id = UUID()
        var date: Date
    }

    private let original: Medication?

    @State private var name: String
    @State private var dose: String
    @State private var note: String
    @State private var remindersEnabled: Bool
    @State private var times: [EditableTime]
    @State private var confirmDelete = false

    init(medication: Medication?) {
        original = medication
        _name = State(initialValue: medication?.name ?? "")
        _dose = State(initialValue: medication?.dose ?? "")
        _note = State(initialValue: medication?.note ?? "")
        _remindersEnabled = State(initialValue: medication?.remindersEnabled ?? true)
        let initial = (medication?.times ?? []).sorted().map { EditableTime(date: $0.date()) }
        _times = State(initialValue: initial)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    TextField("Дозировка, например 50 мг", text: $dose)
                    TextField("Примечание, например после еды", text: $note)
                } header: {
                    Text("Лекарство")
                }

                Section {
                    ForEach($times) { $time in
                        DatePicker("Время приёма", selection: $time.date, displayedComponents: .hourAndMinute)
                    }
                    .onDelete { offsets in
                        times.remove(atOffsets: offsets)
                    }
                    Button {
                        addTime()
                    } label: {
                        Label("Добавить время приёма", systemImage: "plus.circle.fill")
                    }
                    Toggle("Напоминать о приёме", isOn: $remindersEnabled)
                        .disabled(times.isEmpty)
                } header: {
                    Text("Расписание")
                } footer: {
                    Text("Уведомление приходит каждый день в указанное время. Без расписания лекарство считается принимаемым по необходимости. Чтобы убрать время, смахните строку влево.")
                }

                if original != nil {
                    Section {
                        Button("Удалить лекарство", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "Новое лекарство" : "Лекарство")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Удалить лекарство?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let original {
                        store.delete(medication: original)
                    }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Напоминания о нём перестанут приходить. Уже сделанные отметки о приёме сохранятся.")
            }
        }
    }

    private func addTime() {
        let defaults = [8, 20, 14, 12, 18, 22]
        let used = Set(times.map { TimeOfDay(date: $0.date).hour })
        let hour = defaults.first { !used.contains($0) } ?? 9
        let date = TimeOfDay(hour: hour, minute: 0).date()
        times.append(EditableTime(date: date))
    }

    private func save() {
        var medication = original ?? Medication(name: "")
        medication.name = name.trimmingCharacters(in: .whitespaces)
        medication.dose = dose.trimmingCharacters(in: .whitespaces)
        medication.note = note.trimmingCharacters(in: .whitespaces)
        let unique = Set(times.map { TimeOfDay(date: $0.date) })
        medication.times = unique.sorted()
        medication.remindersEnabled = remindersEnabled && !unique.isEmpty
        store.save(medication: medication)
        dismiss()
    }
}
