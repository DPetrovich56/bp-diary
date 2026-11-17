import SwiftUI
import PhotosUI
import UIKit

/// Вкладка «Помощник»: анализ дневника и справка о лекарствах с помощью ИИ.
struct AssistantView: View {
    @EnvironmentObject private var store: DiaryStore
    @StateObject private var assistant = AIAssistant.shared
    @StateObject private var onDevice = OnDeviceAI.shared

    var body: some View {
        NavigationStack {
            Group {
                if assistant.hasConversation || assistant.isWorking {
                    ConversationView()
                } else {
                    AssistantStartView()
                }
            }
            .navigationTitle("Помощник")
            .sheet(item: $assistant.pending) { request in
                ConsentView(request: request)
                    .presentationDetents([.large])
            }
        }
        .environmentObject(assistant)
        .environmentObject(onDevice)
    }
}

// MARK: - Начальный экран

private struct AssistantStartView: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var assistant: AIAssistant
    @EnvironmentObject private var onDevice: OnDeviceAI

    @State private var days = 30
    @State private var question = ""
    @State private var includeNotes = false

    @State private var selectedMedication = ""
    @State private var customMedication = ""
    @State private var leafletImages: [UIImage] = []
    @State private var leafletText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var isRecognizing = false
    @State private var showLeafletText = false
    /// Перерисовка после возврата из настроек сервиса (ключи хранятся вне SwiftUI).
    @State private var refresh = 0

    private let otherTag = "__other__"

    private var provider: AIProviderKind { store.settings.ai.provider }

    private var medicationName: String {
        if selectedMedication == otherTag || store.medications.isEmpty {
            return customMedication.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedMedication
    }

    var body: some View {
        let _ = refresh
        Form {
            serviceSection
            analysisSection
            medicationSection
            Section {
                Text("Помощник разбирает ваши записи и инструкции к лекарствам, но не ставит диагнозы и не назначает лечение. Решения о лечении и дозировках принимает только врач.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            refresh += 1
            if selectedMedication.isEmpty {
                selectedMedication = store.medications.first?.title ?? otherTag
            }
        }
        .onChange(of: photoItems) { _, items in
            loadPhotos(items)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image {
                    leafletImages.append(image)
                    recognize()
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Сервис

    private var serviceSection: some View {
        Section {
            NavigationLink {
                AIServicesView()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: provider.title)
                        .font(.headline)
                    Text(verbatim: serviceStatus)
                        .font(.caption)
                        .foregroundStyle(serviceReady ? Color.secondary : Color.orange)
                }
            }
        } header: {
            Text("Сервис ИИ")
        }
    }

    private var serviceReady: Bool {
        if provider == .onDevice {
            return onDevice.isDownloaded(onDevice.model) && onDevice.isSupported(onDevice.model)
        }
        return KeychainStore.hasKey(for: provider)
    }

    private var serviceStatus: String {
        if provider == .onDevice {
            if !onDevice.isSupported(onDevice.model) { return "Не поддерживается на этом устройстве — выберите облачный сервис" }
            if onDevice.isDownloaded(onDevice.model) { return "Готова к работе, данные не покидают телефон" }
            return "Модель не скачана — нажмите, чтобы скачать"
        }
        return KeychainStore.hasKey(for: provider)
            ? "Подключён. Перед отправкой данных приложение спросит разрешение"
            : "Не подключён — нажмите, чтобы войти и указать ключ"
    }

    // MARK: Анализ

    private var analysisSection: some View {
        Section {
            Picker("Период", selection: $days) {
                Text("7 дней").tag(7)
                Text("30 дней").tag(30)
                Text("90 дней").tag(90)
            }
            .pickerStyle(.segmented)

            TextField("Свой вопрос (необязательно)", text: $question, axis: .vertical)
                .lineLimit(1...4)

            Toggle("Добавить мои заметки", isOn: $includeNotes)

            Button {
                assistant.startAnalysis(days: days, question: question, includeNotes: includeNotes)
            } label: {
                Label("Проанализировать дневник", systemImage: "waveform.path.ecg")
            }
            .disabled(!serviceReady || store.entries.isEmpty)
        } header: {
            Text("Анализ дневника")
        } footer: {
            if store.entries.isEmpty {
                Text("Сначала добавьте замеры в дневник.")
            } else if provider == .onDevice && days > 30 {
                Text("Встроенная модель разбирает не больше 30 последних дней.")
            } else {
                Text("Отправляются только замеры, лекарства, самочувствие и погодные показатели — без имени, контактов и места. Заметки — только если включить переключатель.")
            }
        }
    }

    // MARK: Лекарство

    private var medicationSection: some View {
        Section {
            if !store.medications.isEmpty {
                Picker("Лекарство", selection: $selectedMedication) {
                    ForEach(store.medications) { medication in
                        Text(verbatim: medication.title).tag(medication.title)
                    }
                    Text("Другое").tag(otherTag)
                }
            }
            if store.medications.isEmpty || selectedMedication == otherTag {
                TextField("Название лекарства", text: $customMedication)
                    .textInputAutocapitalization(.words)
            }

            HStack {
                Button {
                    showCamera = true
                } label: {
                    Label("Сфотографировать", systemImage: "camera")
                }
                .buttonStyle(.borderless)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                Spacer()

                PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                    Label("Из фото", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderless)
            }

            if isRecognizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Распознаю текст…")
                        .foregroundStyle(.secondary)
                }
            } else if !leafletText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Фото: \(leafletImages.count), распознано символов: \(leafletText.count)")
                        .font(.footnote)
                    HStack {
                        Button(showLeafletText ? "Скрыть текст" : "Показать текст") {
                            showLeafletText.toggle()
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Убрать фото", role: .destructive) {
                            leafletImages = []
                            leafletText = ""
                            photoItems = []
                        }
                        .buttonStyle(.borderless)
                    }
                    if showLeafletText {
                        Text(verbatim: leafletText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Button {
                assistant.startMedicationInfo(
                    name: medicationName,
                    leafletText: leafletText.isEmpty ? nil : leafletText
                )
            } label: {
                Label("Получить справку", systemImage: "pills")
            }
            .disabled(!serviceReady || medicationName.isEmpty || isRecognizing)
        } header: {
            Text("Справка о лекарстве")
        } footer: {
            Text(verbatim: medicationFooter)
        }
    }

    private var medicationFooter: String {
        let config = store.settings.ai.config(for: provider)
        let search = (provider == .perplexity || provider == .aitunnel) && config.model.hasPrefix("sonar")
        var text = "Лучше всего сфотографировать вкладыш-инструкцию из упаковки (все страницы с нужными разделами): текст распознаётся на iPhone, и ответ строится по официальной инструкции."
        if search {
            text += " Без фото выбранный сервис найдёт инструкцию в интернете и укажет источники."
        } else {
            text += " Без фото модель ответит по своим знаниям — такие сведения нужно сверить с инструкцией."
        }
        return text
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isRecognizing = true
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            leafletImages = images
            recognize()
        }
    }

    private func recognize() {
        let images = leafletImages
        guard !images.isEmpty else {
            isRecognizing = false
            return
        }
        isRecognizing = true
        Task {
            let text = (try? await LeafletScanner.recognizeText(in: images)) ?? ""
            leafletText = text
            isRecognizing = false
        }
    }
}

// MARK: - Разговор

private struct ConversationView: View {
    @EnvironmentObject private var assistant: AIAssistant
    @State private var followUp = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let provider = assistant.conversationProvider {
                            Text(verbatim: provider.isCloud
                                 ? "Сервис: \(provider.title)"
                                 : "Встроенная модель — данные не покидают телефон")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(assistant.messages.filter { $0.role != .system }) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if assistant.isWorking {
                            if assistant.streamingText.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text(verbatim: waitingText)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            } else {
                                MessageBubble(message: AIMessage(role: .assistant, text: assistant.streamingText))
                            }
                        }
                        if let error = assistant.errorText {
                            Label {
                                Text(verbatim: error)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.callout)
                            .padding(.horizontal)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical)
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: assistant.streamingText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Уточняющий вопрос", text: $followUp, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                if assistant.isWorking {
                    Button {
                        assistant.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel(Text("Остановить"))
                } else {
                    Button {
                        assistant.ask(followUp)
                        followUp = ""
                        inputFocused = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(Text("Отправить"))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Новый") {
                    assistant.reset()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let last = assistant.messages.last(where: { $0.role == .assistant }) {
                    ShareLink(item: last.text) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var waitingText: String {
        guard let provider = assistant.conversationProvider else { return "Готовлю ответ…" }
        if provider == .onDevice {
            switch OnDeviceAI.shared.state {
            case .loading: return "Загружаю модель в память…"
            case .downloading(let value): return "Скачиваю модель: \(Int(value * 100))%"
            default: return "Модель обдумывает ответ…"
            }
        }
        return "Жду ответ сервиса…"
    }
}

private struct MessageBubble: View {
    let message: AIMessage

    var body: some View {
        let isUser = message.role == .user
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message.displayText ?? message.text)
                .textSelection(.enabled)
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Источники:")
                        .font(.caption.bold())
                    ForEach(Array(message.sources.enumerated()), id: \.offset) { index, source in
                        if let url = URL(string: source) {
                            Link(destination: url) {
                                Text(verbatim: "\(index + 1). \(url.host ?? source)")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
        )
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal)
    }
}

// MARK: - Согласие на отправку

struct ConsentView: View {
    @EnvironmentObject private var assistant: AIAssistant
    let request: AIAssistant.PendingRequest
    @State private var showPayload = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(verbatim: "Данные будут отправлены в сервис «\(request.provider.title)» для ответа на запрос «\(request.title.lowercased())». Сервис находится вне вашего телефона.")
                    } icon: {
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Section {
                    Label("Замеры давления и пульса с датой и временем", systemImage: "checkmark")
                    Label("Лекарства, дозировки и отметки о приёме", systemImage: "checkmark")
                    Label("Самочувствие и симптомы", systemImage: "checkmark")
                    Label("Погодные показатели без названия места", systemImage: "checkmark")
                    if request.includesNotes {
                        Label("Ваши заметки (вы включили их)", systemImage: "checkmark")
                    }
                } header: {
                    Text("Что будет отправлено")
                }

                Section {
                    Label("Имя, телефон, почта и любые контакты", systemImage: "xmark")
                    Label("Город и геопозиция", systemImage: "xmark")
                    Label("Названия приборов и приложений", systemImage: "xmark")
                    if !request.includesNotes {
                        Label("Заметки", systemImage: "xmark")
                    }
                } header: {
                    Text("Не отправляется")
                }

                Section {
                    Button(showPayload ? "Скрыть текст запроса" : "Показать полный текст запроса") {
                        showPayload.toggle()
                    }
                    if showPayload {
                        Text(verbatim: request.payload)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Сервис обрабатывает данные по своим правилам. Ответ ИИ — не медицинское заключение.")
                }
            }
            .navigationTitle("Отправить данные?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        assistant.confirmPending()
                    } label: {
                        Text("Отправить")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Отмена", role: .cancel) {
                        assistant.cancelPending()
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Камера

struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.completion(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.completion(nil)
            parent.dismiss()
        }
    }
}
