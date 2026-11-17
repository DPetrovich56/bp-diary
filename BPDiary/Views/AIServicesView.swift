import SwiftUI
import SafariServices
import UIKit

/// Выбор сервиса ИИ.
struct AIServicesView: View {
    @EnvironmentObject private var store: DiaryStore
    @ObservedObject private var onDevice = OnDeviceAI.shared
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        List {
            Section {
                ForEach(AIProviderKind.allCases) { kind in
                    NavigationLink {
                        AIProviderDetailView(kind: kind)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: store.settings.ai.provider == kind ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(store.settings.ai.provider == kind ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: kind.title)
                                    .font(.headline)
                                Text(verbatim: kind.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: status(of: kind))
                                    .font(.caption)
                                    .foregroundStyle(isReady(kind) ? Color.green : Color.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Сервис для помощника")
            } footer: {
                Text("Встроенная модель работает на телефоне и ничего никуда не отправляет. Облачные сервисы отвечают точнее, но перед каждой отправкой данных приложение показывает, что именно уйдёт, и спрашивает разрешение. Ключи доступа хранятся в защищённом хранилище iPhone.")
            }
        }
        .navigationTitle("ИИ-помощник")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh += 1 }
    }

    private func isReady(_ kind: AIProviderKind) -> Bool {
        if kind == .onDevice {
            return onDevice.isDownloaded(onDevice.model) && onDevice.isSupported(onDevice.model)
        }
        return KeychainStore.hasKey(for: kind)
    }

    private func status(of kind: AIProviderKind) -> String {
        if kind == .onDevice {
            if !onDevice.isSupported(onDevice.model) { return "Не поддерживается на этом устройстве" }
            switch onDevice.state {
            case .downloading(let value): return "Скачивается: \(Int(value * 100))%"
            default: break
            }
            return onDevice.isDownloaded(onDevice.model) ? "Модель скачана" : "Модель не скачана"
        }
        return KeychainStore.hasKey(for: kind) ? "Ключ сохранён" : "Не подключён"
    }
}

/// Настройка одного сервиса: регистрация и вход, ключ, модель, проверка.
struct AIProviderDetailView: View {
    let kind: AIProviderKind

    @EnvironmentObject private var store: DiaryStore
    @ObservedObject private var onDevice = OnDeviceAI.shared

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var config = AIProviderConfig()
    @State private var safariURL: SafariTarget?
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var confirmDeleteModel = false

    private var isSelected: Bool { store.settings.ai.provider == kind }

    var body: some View {
        Form {
            Section {
                Text(verbatim: kind.subtitle)
                    .foregroundStyle(.secondary)
            }

            if kind == .onDevice {
                onDeviceSections
            } else {
                cloudSections
            }

            Section {
                Button {
                    store.updateAI { $0.provider = kind }
                } label: {
                    Label(
                        isSelected ? "Этот сервис используется" : "Использовать этот сервис",
                        systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                    )
                }
                .disabled(isSelected)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $safariURL) { target in
            SafariView(url: target.url)
                .ignoresSafeArea()
        }
        .onAppear {
            config = store.settings.ai.config(for: kind)
            hasKey = KeychainStore.hasKey(for: kind)
        }
    }

    // MARK: - Встроенная модель

    @ViewBuilder
    private var onDeviceSections: some View {
        Section {
            Picker("Модель", selection: modelBinding) {
                ForEach(OnDeviceModel.allCases, id: \.self) { model in
                    Text(verbatim: model.title).tag(model)
                }
            }
            .disabled(isDownloading)

            if !onDevice.isSupported(onDevice.model) {
                Text("На этом устройстве модель не запустится: нужен iPhone 15 Pro или новее (для облегчённой модели — iPhone с 6 ГБ памяти). Выберите облачный сервис.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            switch onDevice.state {
            case .notDownloaded:
                Button {
                    onDevice.download(mirror: store.settings.ai.mirror)
                } label: {
                    Label("Скачать модель (\(onDevice.model.approximateSize))", systemImage: "arrow.down.circle")
                }
                .disabled(!onDevice.isSupported(onDevice.model))
            case .downloading(let value):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: value)
                    Text(verbatim: "Скачано \(Int(value * 100))%. Не закрывайте приложение.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Отменить загрузку", role: .destructive) {
                    onDevice.cancelDownload()
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаю модель…")
                }
            case .ready:
                Label("Модель скачана и готова", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Удалить модель с телефона", role: .destructive) {
                    confirmDeleteModel = true
                }
            case .failed(let message):
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button {
                    onDevice.download(mirror: store.settings.ai.mirror)
                } label: {
                    Label("Повторить загрузку", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Модель на телефоне")
        } footer: {
            Text("Модель скачивается один раз, лучше по Wi-Fi. После этого помощник работает без интернета, а ваши данные не покидают телефон. Ответы встроенной модели проще и могут содержать неточности.")
        }
        .confirmationDialog("Удалить модель?", isPresented: $confirmDeleteModel, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                onDevice.deleteModel(onDevice.model)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится около \(onDevice.model.approximateSize). Скачать её можно будет снова.")
        }

        Section {
            Picker("Сервер загрузки", selection: mirrorBinding) {
                ForEach(ModelMirror.allCases) { mirror in
                    Text(verbatim: mirror.title).tag(mirror)
                }
            }
        } footer: {
            Text("Если загрузка с Hugging Face не идёт, выберите зеркало и повторите.")
        }
    }

    private var isDownloading: Bool {
        if case .downloading = onDevice.state { return true }
        return false
    }

    private var modelBinding: Binding<OnDeviceModel> {
        Binding(
            get: { onDevice.model },
            set: { onDevice.select($0) }
        )
    }

    private var mirrorBinding: Binding<ModelMirror> {
        Binding(
            get: { store.settings.ai.mirror },
            set: { value in store.updateAI { $0.mirror = value } }
        )
    }

    // MARK: - Облачный сервис

    @ViewBuilder
    private var cloudSections: some View {
        if let url = kind.signupURL {
            Section {
                Button {
                    safariURL = SafariTarget(url: url)
                } label: {
                    Label("Регистрация и вход", systemImage: "person.crop.circle.badge.plus")
                }
                ForEach(Array(kind.keySteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption.bold())
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        Text(verbatim: step)
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("Как подключить")
            } footer: {
                Text("Страница сервиса откроется внутри приложения: там можно зарегистрироваться или войти в существующий аккаунт и получить ключ.")
            }
        } else {
            Section {
                ForEach(Array(kind.keySteps.enumerated()), id: \.offset) { _, step in
                    Text(verbatim: step)
                        .font(.subheadline)
                }
            } header: {
                Text("Как подключить")
            }
        }

        Section {
            if kind.needsBaseURL {
                TextField("Адрес API, например https://…/v1", text: $config.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if kind.needsFolderID {
                TextField("Идентификатор каталога (folder ID)", text: $config.folderID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if !kind.models.isEmpty {
                Picker("Модель", selection: $config.model) {
                    ForEach(kind.models) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                    if !kind.models.contains(where: { $0.id == config.model }) && !config.model.isEmpty {
                        Text(verbatim: config.model).tag(config.model)
                    }
                }
            }
            if kind.allowsCustomModel {
                TextField("Модель (идентификатор)", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if hasKey {
                Label("Ключ сохранён", systemImage: "key.fill")
                    .foregroundStyle(.green)
            }
            SecureField(hasKey ? "Новый ключ (если нужно заменить)" : "Ключ доступа", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                if let text = UIPasteboard.general.string {
                    keyInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Label("Вставить ключ из буфера обмена", systemImage: "doc.on.clipboard")
            }

            Button {
                save()
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty && config == store.settings.ai.config(for: kind))
        } header: {
            Text("Доступ")
        }

        Section {
            Button {
                save()
                isTesting = true
                testResult = nil
                let currentConfig = config
                Task {
                    testResult = await AIAssistant.testConnection(provider: kind, config: currentConfig)
                    isTesting = false
                }
            } label: {
                HStack {
                    Label("Проверить подключение", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting || (!hasKey && keyInput.isEmpty))
            if let testResult {
                Text(verbatim: testResult)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if hasKey {
                Button("Удалить ключ", role: .destructive) {
                    KeychainStore.setKey(nil, for: kind)
                    hasKey = false
                    testResult = nil
                }
            }
        } footer: {
            Text("Проверка отправляет короткий тестовый вопрос без ваших данных.")
        }
    }

    private func save() {
        let trimmedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            KeychainStore.setKey(trimmedKey, for: kind)
            keyInput = ""
            hasKey = KeychainStore.hasKey(for: kind)
        }
        var cleaned = config
        cleaned.model = cleaned.model.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.folderID = cleaned.folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.baseURL = cleaned.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config = cleaned
        store.updateAI { $0.configs[kind.rawValue] = cleaned }
    }
}

struct SafariTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// Встроенный браузер Safari для регистрации и входа в сервис.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
