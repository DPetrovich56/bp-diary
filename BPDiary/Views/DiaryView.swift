import SwiftUI

/// Вкладка «Дневник»: список замеров по дням.
struct DiaryView: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var router: AppRouter

    @State private var editing: BPEntry?
    @State private var pendingDelete: BPEntry?

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [BPEntry]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.entries) { calendar.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)
        return days.map { DayGroup(day: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Дневник")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        router.openNewEntry()
                    } label: {
                        Label("Новый замер", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { entry in
                EntryEditorView(entry: entry)
            }
            .confirmationDialog(
                "Удалить запись?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let entry = pendingDelete {
                        store.delete(entry: entry)
                    }
                    pendingDelete = nil
                }
                Button("Отмена", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text(deleteMessage)
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented { pendingDelete = nil }
            }
        )
    }

    private var deleteMessage: String {
        guard let entry = pendingDelete else { return "" }
        if entry.isImported {
            return "Замер получен из «Здоровья». Он исчезнет из дневника, но останется в «Здоровье»."
        }
        if entry.healthSynced {
            return "Замер будет удалён из дневника и из «Здоровья»."
        }
        return "Замер будет удалён из дневника."
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Пока нет записей", systemImage: "heart.text.square")
        } description: {
            Text("Измерьте давление и добавьте первую запись.")
        } actions: {
            Button("Добавить замер") {
                router.openNewEntry()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            if let latest = store.entries.first {
                Section {
                    LatestSummaryView(latest: latest, weekEntries: store.entries(inLast: 7))
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        Button {
                            editing = entry
                        } label: {
                            EntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingDelete = entry
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Text(verbatim: DayTitle.text(for: group.day))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// Карточка с последним замером и средним за неделю.
struct LatestSummaryView: View {
    let latest: BPEntry
    let weekEntries: [BPEntry]

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Последний замер")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: latest.pressureTitle)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Circle()
                        .fill(latest.category.color)
                        .frame(width: 10, height: 10)
                    Text(verbatim: latest.category.title)
                        .font(.subheadline)
                }
                Text(verbatim: DayTitle.dayAndTime(latest.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let summary = Statistics.summary(of: weekEntries) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Среднее за 7 дней")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(summary.averageSystolic)/\(summary.averageDiastolic)")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let pulse = summary.averagePulse {
                        Text(verbatim: "пульс \(pulse)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: "замеров: \(summary.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Строка одного замера в списке.
struct EntryRow: View {
    let entry: BPEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(entry.category.color)
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: entry.pressureTitle)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let pulse = entry.pulse {
                        Label {
                            Text(verbatim: "\(pulse)")
                        } icon: {
                            Image(systemName: "heart.fill")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: DayTitle.time(entry.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(verbatim: entry.category.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let line = wellbeingLine {
                    detail(symbol: "figure.mind.and.body", text: line)
                }
                if !entry.medications.isEmpty {
                    detail(symbol: "pills", text: entry.medications.map { $0.title }.joined(separator: ", "))
                }
                if let weather = entry.weather {
                    detail(symbol: weather.symbolName, text: weather.summary)
                }
                if !entry.note.isEmpty {
                    detail(symbol: "note.text", text: entry.note)
                }
                if entry.isImported {
                    detail(symbol: "heart.circle", text: "Из «Здоровья»: \(entry.healthSourceName ?? "другое приложение")")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var wellbeingLine: String? {
        var parts: [String] = []
        if let wellbeing = entry.wellbeing {
            parts.append("\(wellbeing.emoji) \(wellbeing.title)")
        }
        if !entry.symptoms.isEmpty {
            parts.append(entry.symptoms.joined(separator: ", ").lowercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func detail(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
