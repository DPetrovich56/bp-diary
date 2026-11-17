import Foundation
import SwiftUI

/// Разговор с ИИ-помощником: подготовка обезличенных данных, согласие на отправку, ответы.
@MainActor
final class AIAssistant: ObservableObject {
    static let shared = AIAssistant()

    /// Запрос, ожидающий согласия пользователя на отправку в облачный сервис.
    struct PendingRequest: Identifiable {
        let id = UUID()
        let title: String
        let provider: AIProviderKind
        let messages: [AIMessage]
        /// Что именно уйдёт в сервис — показывается пользователю полностью.
        let payload: String
        let includesNotes: Bool
    }

    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var isWorking = false
    @Published private(set) var streamingText = ""
    @Published var errorText: String?
    @Published var pending: PendingRequest?
    /// Сервис, с которым идёт текущий разговор.
    @Published private(set) var conversationProvider: AIProviderKind?

    private var currentTask: Task<Void, Never>?

    private init() {}

    var hasConversation: Bool { messages.contains { $0.role != .system } }

    private var store: DiaryStore { DiaryStore.shared }
    private var settings: AISettings { store.settings.ai }

    // MARK: - Запуск сценариев

    func startAnalysis(days: Int, question: String, includeNotes: Bool) {
        let provider = settings.provider
        let detail: AIPrompts.Detail = provider == .onDevice ? .compact : .full
        let summary = AIPrompts.diarySummary(
            entries: store.entries,
            medications: store.medications,
            intakes: store.intakes,
            days: days,
            detail: detail,
            includeNotes: includeNotes
        )
        var userText = summary
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuestion.isEmpty {
            userText += "\n\nВОПРОС ПОЛЬЗОВАТЕЛЯ: \(trimmedQuestion)"
        } else {
            userText += "\n\nПроанализируй дневник по структуре из инструкции."
        }

        var display = "Проанализируй мой дневник за \(days) дн."
        if !trimmedQuestion.isEmpty { display += "\nВопрос: \(trimmedQuestion)" }

        let request: [AIMessage] = [
            AIMessage(role: .system, text: AIPrompts.analysisInstructions),
            AIMessage(role: .user, text: userText, displayText: display)
        ]
        submit(
            title: "Анализ дневника",
            provider: provider,
            messages: request,
            payload: userText,
            includesNotes: includeNotes
        )
    }

    func startMedicationInfo(name: String, leafletText: String?) {
        let provider = settings.provider
        let config = settings.config(for: provider)
        let webSearch = (provider == .perplexity || provider == .aitunnel) && config.model.hasPrefix("sonar")
        var leaflet = leafletText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = leaflet, !text.isEmpty {
            // Встроенной модели даём меньше текста: у неё небольшое окно контекста.
            let limit = provider == .onDevice ? 7_000 : 40_000
            if text.count > limit {
                leaflet = String(text.prefix(limit)) + "\n[…текст сокращён…]"
            }
        } else {
            leaflet = nil
        }
        let others = store.medications
            .map { $0.title }
            .filter { $0.lowercased() != name.lowercased() }
        let userText = AIPrompts.medicationRequest(name: name, otherMedications: others, leafletText: leaflet)

        var display = "Справка о лекарстве: \(name)"
        if leaflet != nil { display += "\n(по фото инструкции)" }

        let request: [AIMessage] = [
            AIMessage(
                role: .system,
                text: AIPrompts.medicationInstructions(hasLeaflet: leaflet != nil, webSearch: webSearch)
            ),
            AIMessage(role: .user, text: userText, displayText: display)
        ]
        submit(
            title: "Справка о лекарстве",
            provider: provider,
            messages: request,
            payload: userText,
            includesNotes: false
        )
    }

    /// Уточняющий вопрос в текущем разговоре.
    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking, let provider = conversationProvider else { return }
        messages.append(AIMessage(role: .user, text: trimmed))
        run(provider: provider, messages: messages)
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        messages = []
        streamingText = ""
        isWorking = false
        errorText = nil
        conversationProvider = nil
    }

    func stop() {
        currentTask?.cancel()
    }

    // MARK: - Согласие

    private func submit(
        title: String,
        provider: AIProviderKind,
        messages request: [AIMessage],
        payload: String,
        includesNotes: Bool
    ) {
        errorText = nil
        if provider.isCloud {
            pending = PendingRequest(
                title: title,
                provider: provider,
                messages: request,
                payload: payload,
                includesNotes: includesNotes
            )
        } else {
            begin(provider: provider, messages: request)
        }
    }

    func confirmPending() {
        guard let request = pending else { return }
        pending = nil
        begin(provider: request.provider, messages: request.messages)
    }

    func cancelPending() {
        pending = nil
    }

    private func begin(provider: AIProviderKind, messages request: [AIMessage]) {
        currentTask?.cancel()
        messages = request
        conversationProvider = provider
        run(provider: provider, messages: request)
    }

    // MARK: - Выполнение

    private func run(provider: AIProviderKind, messages request: [AIMessage]) {
        isWorking = true
        streamingText = ""
        errorText = nil
        let config = settings.config(for: provider)
        let mirror = settings.mirror

        currentTask = Task { @MainActor in
            defer {
                self.isWorking = false
                self.currentTask = nil
            }
            do {
                if provider == .onDevice {
                    var text = ""
                    for try await chunk in OnDeviceAI.shared.stream(messages: request, mirror: mirror) {
                        text += chunk
                        self.streamingText = text
                    }
                    let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !final.isEmpty else { throw AIError.emptyAnswer }
                    self.messages.append(AIMessage(role: .assistant, text: final))
                } else {
                    let reply = try await CloudAIClient.shared.complete(
                        provider: provider,
                        config: config,
                        messages: request
                    )
                    try Task.checkCancellation()
                    self.messages.append(AIMessage(role: .assistant, text: reply.text, sources: reply.sources))
                }
                self.streamingText = ""
            } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
                let partial = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    self.messages.append(AIMessage(role: .assistant, text: partial + "\n\n[остановлено]"))
                }
                self.streamingText = ""
            } catch {
                self.streamingText = ""
                self.errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Проверка подключения

    static func testConnection(provider: AIProviderKind, config: AIProviderConfig) async -> String {
        guard provider.isCloud else { return "" }
        let messages = [
            AIMessage(role: .system, text: "Отвечай очень кратко, по-русски."),
            AIMessage(role: .user, text: "Ответь одним словом: «работает».")
        ]
        do {
            let reply = try await CloudAIClient.shared.complete(
                provider: provider,
                config: config,
                messages: messages,
                temperature: 0,
                maxTokens: 20
            )
            return "✅ Подключено. Ответ сервиса: \(reply.text.prefix(60))"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }
}
