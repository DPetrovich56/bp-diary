import Foundation
import SwiftUI
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Встроенная языковая модель: скачивается один раз и работает на iPhone без интернета.
@MainActor
final class OnDeviceAI: ObservableObject {
    static let shared = OnDeviceAI()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded
    @Published private(set) var model: OnDeviceModel = .standard

    private var container: ModelContainer?
    private var loadedModel: OnDeviceModel?
    private var loadTask: Task<ModelContainer, Error>?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "onDeviceModel"),
           let saved = OnDeviceModel(rawValue: raw) {
            model = saved
        }
        state = isDownloaded(model) ? .ready : .notDownloaded
    }

    // MARK: - Где лежит модель

    /// Модели хранятся в папке приложения, а не в кэше, чтобы iOS не удаляла их при нехватке места.
    static var cacheDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }

    private static func folder(for model: OnDeviceModel) -> URL {
        let name = "models--" + model.rawValue.replacingOccurrences(of: "/", with: "--")
        return cacheDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private static func downloadedFlag(for model: OnDeviceModel) -> String {
        "onDeviceModelDownloaded." + model.rawValue
    }

    func isDownloaded(_ model: OnDeviceModel) -> Bool {
        UserDefaults.standard.bool(forKey: OnDeviceAI.downloadedFlag(for: model))
            && FileManager.default.fileExists(atPath: OnDeviceAI.folder(for: model).path)
    }

    // MARK: - Возможности устройства

    /// Сколько оперативной памяти нужно модели (с запасом).
    private static func requiredMemory(for model: OnDeviceModel) -> UInt64 {
        switch model {
        case .standard: return 7_000_000_000
        case .compact: return 5_500_000_000
        }
    }

    func isSupported(_ model: OnDeviceModel) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ProcessInfo.processInfo.physicalMemory >= OnDeviceAI.requiredMemory(for: model)
        #endif
    }

    // MARK: - Выбор, загрузка, удаление

    func select(_ newModel: OnDeviceModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: "onDeviceModel")
        container = nil
        loadedModel = nil
        loadTask?.cancel()
        loadTask = nil
        state = isDownloaded(newModel) ? .ready : .notDownloaded
    }

    func download(mirror: ModelMirror) {
        guard loadTask == nil else { return }
        guard isSupported(model) else {
            state = .failed(AIError.unsupportedDevice.localizedDescription)
            return
        }
        Task {
            do {
                _ = try await loadContainer(mirror: mirror)
            } catch {
                // Состояние уже выставлено в loadContainer.
            }
        }
    }

    func cancelDownload() {
        loadTask?.cancel()
        loadTask = nil
        state = isDownloaded(model) ? .ready : .notDownloaded
    }

    func deleteModel(_ target: OnDeviceModel) {
        if target == model {
            loadTask?.cancel()
            loadTask = nil
            container = nil
            loadedModel = nil
        }
        try? FileManager.default.removeItem(at: OnDeviceAI.folder(for: target))
        UserDefaults.standard.set(false, forKey: OnDeviceAI.downloadedFlag(for: target))
        if target == model {
            state = .notDownloaded
        }
    }

    private func loadContainer(mirror: ModelMirror) async throws -> ModelContainer {
        if let container, loadedModel == model {
            return container
        }
        if let loadTask {
            return try await loadTask.value
        }

        let target = model
        let alreadyDownloaded = isDownloaded(target)
        state = alreadyDownloaded ? .loading : .downloading(0)

        let task = Task<ModelContainer, Error> {
            let hub = HubClient(
                host: mirror.host,
                userAgent: "BPDiary/1.0",
                cache: HubCache(cacheDirectory: OnDeviceAI.cacheDirectory)
            )
            let configuration = ModelConfiguration(
                id: target.rawValue,
                extraEOSTokens: ["<|im_end|>"]
            )
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hub),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progress: .download { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        OnDeviceAI.shared.updateDownload(fraction)
                    }
                }
            )
        }
        loadTask = task

        do {
            let loaded = try await task.value
            loadTask = nil
            container = loaded
            loadedModel = target
            UserDefaults.standard.set(true, forKey: OnDeviceAI.downloadedFlag(for: target))
            state = .ready
            return loaded
        } catch {
            loadTask = nil
            if error is CancellationError {
                state = isDownloaded(target) ? .ready : .notDownloaded
            } else {
                state = .failed("Не удалось загрузить модель: \(error.localizedDescription)")
            }
            throw error
        }
    }

    fileprivate func updateDownload(_ fraction: Double) {
        if case .downloading = state {
            state = .downloading(min(max(fraction, 0), 1))
        }
    }

    // MARK: - Генерация

    /// Ответ модели по частям, по мере генерации.
    func stream(messages: [AIMessage], mirror: ModelMirror) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard self.isSupported(self.model) else { throw AIError.unsupportedDevice }
                    guard self.isDownloaded(self.model) || self.container != nil else {
                        throw AIError.modelNotDownloaded
                    }
                    let container = try await self.loadContainer(mirror: mirror)

                    let instructions = messages.first { $0.role == .system }?.text
                    let history: [Chat.Message] = messages.compactMap { message in
                        switch message.role {
                        case .system: return nil
                        case .user: return .user(message.text)
                        case .assistant: return .assistant(message.text)
                        }
                    }
                    let session = ChatSession(
                        container,
                        instructions: instructions,
                        generateParameters: GenerateParameters(
                            maxTokens: 1500,
                            maxKVSize: 8192,
                            temperature: 0.4,
                            topP: 0.9,
                            repetitionPenalty: 1.05
                        ),
                        additionalContext: ["enable_thinking": false]
                    )
                    var filter = ReasoningFilter()
                    for try await chunk in session.streamResponse(to: history) {
                        try Task.checkCancellation()
                        let visible = filter.feed(chunk)
                        if !visible.isEmpty {
                            continuation.yield(visible)
                        }
                    }
                    let rest = filter.finish()
                    if !rest.isEmpty {
                        continuation.yield(rest)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Скрывает блоки <think>…</think>, если модель всё же начала «размышлять» вслух.
struct ReasoningFilter {
    private var buffer = ""
    private var insideThink = false

    /// Остаток текста после окончания генерации.
    mutating func finish() -> String {
        defer { buffer = "" }
        return insideThink ? "" : buffer
    }

    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var output = ""
        while true {
            if insideThink {
                guard let end = buffer.range(of: "</think>") else {
                    // Держим хвост, чтобы не потерять разорванный тег.
                    if buffer.count > 16 { buffer = String(buffer.suffix(16)) }
                    return output
                }
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                insideThink = false
            } else {
                if let start = buffer.range(of: "<think>") {
                    output += buffer[buffer.startIndex..<start.lowerBound]
                    buffer.removeSubrange(buffer.startIndex..<start.upperBound)
                    insideThink = true
                } else {
                    // Отдаём всё, кроме возможного начала тега в конце.
                    let keep = min(buffer.count, 7)
                    let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
                    let tail = String(buffer[cut...])
                    if "<think>".hasPrefix(tail) || tail.contains("<") {
                        output += buffer[buffer.startIndex..<cut]
                        buffer = tail
                    } else {
                        output += buffer
                        buffer = ""
                    }
                    return output
                }
            }
        }
    }
}
