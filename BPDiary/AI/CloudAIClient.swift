import Foundation
import Security

/// Ответ облачной модели.
struct AIReply {
    var text: String
    var sources: [String]
}

/// Запросы к облачным сервисам в формате OpenAI Chat Completions
/// (GigaChat, YandexGPT, Perplexity, AITUNNEL и совместимые).
final class CloudAIClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = CloudAIClient()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let tokens = GigaChatTokenCache()

    // MARK: - Запрос

    func complete(
        provider: AIProviderKind,
        config: AIProviderConfig,
        messages: [AIMessage],
        temperature: Double = 0.3,
        maxTokens: Int = 1800
    ) async throws -> AIReply {
        guard let key = KeychainStore.key(for: provider) else { throw AIError.missingKey }

        var model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = provider.models.first?.id ?? "" }
        if model.isEmpty { throw AIError.missingSetting("Модель") }

        let endpoint: URL
        var headers: [String: String] = ["Content-Type": "application/json", "Accept": "application/json"]

        switch provider {
        case .onDevice:
            throw AIError.missingKey
        case .gigachat:
            endpoint = URL(string: "https://api.giga.chat/v1/chat/completions")!
            let token = try await tokens.token(authorizationKey: key, session: session)
            headers["Authorization"] = "Bearer \(token)"
        case .yandex:
            let folder = config.folderID.trimmingCharacters(in: .whitespacesAndNewlines)
            if folder.isEmpty { throw AIError.missingSetting("Идентификатор каталога") }
            endpoint = URL(string: "https://llm.api.cloud.yandex.net/v1/chat/completions")!
            headers["Authorization"] = "Api-Key \(key)"
            headers["OpenAI-Project"] = folder
            if !model.hasPrefix("gpt://") {
                model = "gpt://\(folder)/\(model)"
            }
        case .perplexity:
            endpoint = URL(string: "https://api.perplexity.ai/chat/completions")!
            headers["Authorization"] = "Bearer \(key)"
        case .aitunnel:
            endpoint = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!
            headers["Authorization"] = "Bearer \(key)"
        case .custom:
            var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { throw AIError.missingSetting("Адрес API") }
            while base.hasSuffix("/") { base.removeLast() }
            if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
            guard let url = URL(string: base), url.scheme == "https" else {
                throw AIError.missingSetting("Адрес API (должен начинаться с https://)")
            }
            endpoint = url
            headers["Authorization"] = "Bearer \(key)"
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        if provider == .gigachat {
            body["stream"] = false
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if provider == .gigachat, status == 401 {
                await tokens.reset()
            }
            throw AIError.badResponse(status, CloudAIClient.errorMessage(from: data))
        }
        return try CloudAIClient.parse(data)
    }

    // MARK: - Разбор ответа

    static func parse(_ data: Data) throws -> AIReply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.emptyAnswer
        }
        var text = ""
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                text = content
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        text = stripReasoning(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyAnswer }

        var sources: [String] = []
        if let citations = json["citations"] as? [String] {
            sources = citations
        } else if let results = json["search_results"] as? [[String: Any]] {
            sources = results.compactMap { $0["url"] as? String }
        }
        var unique: [String] = []
        for source in sources where !unique.contains(source) {
            unique.append(source)
        }
        return AIReply(text: text, sources: unique)
    }

    /// Убирает «размышления» модели, если она их вернула.
    static func stripReasoning(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
        }
        let raw = String(data: data.prefix(300), encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Сертификат НУЦ Минцифры для серверов Сбера

    private static let russianRootCertificate: SecCertificate? = {
        guard
            let url = Bundle.main.url(forResource: "russian_trusted_root_ca", withExtension: "cer"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }()

    private static func usesRussianRoot(_ host: String) -> Bool {
        host.hasSuffix("sberbank.ru") || host.hasSuffix("giga.chat")
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard
            space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = space.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Обычная проверка по системным корневым сертификатам.
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // Для серверов Сбера дополнительно доверяем корневому сертификату НУЦ Минцифры,
        // встроенному в приложение. Для остальных адресов исключений нет.
        if CloudAIClient.usesRussianRoot(space.host), let root = CloudAIClient.russianRootCertificate {
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

/// Временный токен GigaChat (действует 30 минут) по постоянному ключу авторизации.
actor GigaChatTokenCache {
    private var token: String?
    private var expires: Date = .distantPast
    private var keyUsed: String?

    func reset() {
        token = nil
        expires = .distantPast
    }

    func token(authorizationKey: String, session: URLSession) async throws -> String {
        if let token, keyUsed == authorizationKey, expires > Date().addingTimeInterval(60) {
            return token
        }
        var request = URLRequest(url: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "RqUID")
        let key = authorizationKey.hasPrefix("Basic ") ? String(authorizationKey.dropFirst(6)) : authorizationKey
        request.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("scope=GIGACHAT_API_PERS".utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AIError.badResponse(status, CloudAIClient.errorMessage(from: data))
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = json["access_token"] as? String
        else { throw AIError.emptyAnswer }

        token = value
        keyUsed = authorizationKey
        if let milliseconds = json["expires_at"] as? Double {
            expires = Date(timeIntervalSince1970: milliseconds / 1000)
        } else {
            expires = Date().addingTimeInterval(25 * 60)
        }
        return value
    }
}
