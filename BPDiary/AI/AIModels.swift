import Foundation

// MARK: - Сервисы ИИ

/// Сервис, который отвечает на вопросы помощника.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case onDevice
    case gigachat
    case yandex
    case perplexity
    case aitunnel
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "Встроенная модель"
        case .gigachat: return "GigaChat (Сбер)"
        case .yandex: return "YandexGPT (Яндекс)"
        case .perplexity: return "Perplexity"
        case .aitunnel: return "AITUNNEL"
        case .custom: return "Другой сервис"
        }
    }

    var subtitle: String {
        switch self {
        case .onDevice: return "Бесплатно, работает без интернета, данные не покидают телефон"
        case .gigachat: return "Бесплатный лимит для физлиц, вход через Сбер ID"
        case .yandex: return "Стартовый грант Yandex Cloud, дальше оплата за запросы"
        case .perplexity: return "Поиск в интернете с источниками, оплата зарубежной картой"
        case .aitunnel: return "Perplexity и другие модели с оплатой в рублях"
        case .custom: return "Любой сервис, совместимый с OpenAI API"
        }
    }

    var isCloud: Bool { self != .onDevice }

    /// Где зарегистрироваться или войти, чтобы получить ключ.
    var signupURL: URL? {
        switch self {
        case .onDevice, .custom: return nil
        case .gigachat: return URL(string: "https://developers.sber.ru/studio")
        case .yandex: return URL(string: "https://aistudio.yandex.ru")
        case .perplexity: return URL(string: "https://www.perplexity.ai/account/api")
        case .aitunnel: return URL(string: "https://aitunnel.ru/panel/login")
        }
    }

    /// Пошаговая подсказка, как получить ключ.
    var keySteps: [String] {
        switch self {
        case .onDevice:
            return []
        case .gigachat:
            return [
                "Нажмите «Регистрация и вход» и войдите через Сбер ID.",
                "Создайте проект GigaChat API для физических лиц (тариф Freemium).",
                "В проекте откройте «Настройки API» и нажмите «Получить ключ».",
                "Скопируйте «Ключ авторизации» (Authorization Key) — он показывается один раз — и вставьте его ниже."
            ]
        case .yandex:
            return [
                "Нажмите «Регистрация и вход» и войдите с Яндекс ID. При первом входе создайте платёжный аккаунт — новым пользователям даётся стартовый грант.",
                "Скопируйте идентификатор каталога (folder ID): он показан в AI Studio рядом с названием каталога.",
                "Создайте API-ключ для работы с AI Studio и скопируйте его значение.",
                "Вставьте идентификатор каталога и ключ ниже."
            ]
        case .perplexity:
            return [
                "Нажмите «Регистрация и вход» и войдите в Perplexity.",
                "В разделе API пополните баланс (нужна зарубежная карта).",
                "Создайте API-ключ и вставьте его ниже."
            ]
        case .aitunnel:
            return [
                "Нажмите «Регистрация и вход» и создайте аккаунт.",
                "Пополните баланс в рублях (картой «Мир» или по СБП).",
                "Создайте API-ключ и вставьте его ниже."
            ]
        case .custom:
            return [
                "Укажите адрес API сервиса (обычно заканчивается на /v1), название модели и ключ.",
                "Сервис должен поддерживать запросы в формате OpenAI Chat Completions."
            ]
        }
    }

    /// Модели на выбор (первая — по умолчанию).
    var models: [AIModelOption] {
        switch self {
        case .onDevice:
            return [
                AIModelOption(id: OnDeviceModel.standard.rawValue, title: OnDeviceModel.standard.title),
                AIModelOption(id: OnDeviceModel.compact.rawValue, title: OnDeviceModel.compact.title)
            ]
        case .gigachat:
            return [
                AIModelOption(id: "GigaChat-2", title: "GigaChat Lite — быстрая"),
                AIModelOption(id: "GigaChat-2-Pro", title: "GigaChat Pro"),
                AIModelOption(id: "GigaChat-2-Max", title: "GigaChat Max — самая сильная")
            ]
        case .yandex:
            return [
                AIModelOption(id: "yandexgpt/latest", title: "YandexGPT Pro"),
                AIModelOption(id: "yandexgpt/rc", title: "YandexGPT Pro (новая версия)"),
                AIModelOption(id: "yandexgpt-lite", title: "YandexGPT Lite — дешевле")
            ]
        case .perplexity, .aitunnel:
            return [
                AIModelOption(id: "sonar", title: "Sonar — поиск в интернете"),
                AIModelOption(id: "sonar-pro", title: "Sonar Pro — подробнее, дороже")
            ]
        case .custom:
            return []
        }
    }

    var needsFolderID: Bool { self == .yandex }
    var needsBaseURL: Bool { self == .custom }
    var allowsCustomModel: Bool { self == .aitunnel || self == .custom }
}

struct AIModelOption: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Встроенные модели, которые скачиваются на телефон.
enum OnDeviceModel: String, CaseIterable, Codable {
    case standard = "mlx-community/Qwen3-4B-4bit"
    case compact = "mlx-community/Qwen3-1.7B-4bit"

    var title: String {
        switch self {
        case .standard: return "Qwen3 4B — точнее, около 2,3 ГБ"
        case .compact: return "Qwen3 1.7B — быстрее, около 1 ГБ"
        }
    }

    var approximateSize: String {
        switch self {
        case .standard: return "2,3 ГБ"
        case .compact: return "1 ГБ"
        }
    }
}

/// Настройки одного сервиса (ключи хранятся отдельно, в Keychain).
struct AIProviderConfig: Codable, Hashable {
    var model: String = ""
    var folderID: String = ""
    var baseURL: String = ""
}

/// Сервер, с которого скачивается встроенная модель.
enum ModelMirror: String, Codable, CaseIterable, Identifiable {
    case huggingFace
    case hfMirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .huggingFace: return "Hugging Face"
        case .hfMirror: return "Зеркало hf-mirror.com"
        }
    }

    var host: URL {
        switch self {
        case .huggingFace: return URL(string: "https://huggingface.co")!
        case .hfMirror: return URL(string: "https://hf-mirror.com")!
        }
    }
}

struct AISettings: Codable, Hashable {
    var provider: AIProviderKind = .onDevice
    var configs: [String: AIProviderConfig] = [:]
    var mirror: ModelMirror = .huggingFace

    enum CodingKeys: String, CodingKey {
        case provider, configs, mirror
    }

    func config(for kind: AIProviderKind) -> AIProviderConfig {
        var config = configs[kind.rawValue] ?? AIProviderConfig()
        if config.model.isEmpty, let first = kind.models.first {
            config.model = first.id
        }
        return config
    }
}

extension AISettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decodeIfPresent(AIProviderKind.self, forKey: .provider)) ?? .onDevice
        configs = (try? c.decodeIfPresent([String: AIProviderConfig].self, forKey: .configs)) ?? [:]
        mirror = (try? c.decodeIfPresent(ModelMirror.self, forKey: .mirror)) ?? .huggingFace
    }
}

// MARK: - Переписка с помощником

struct AIMessage: Identifiable, Hashable {
    enum Role: String {
        case system
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var text: String
    /// Что показать пользователю вместо полного текста (например, вместо таблицы замеров).
    var displayText: String?
    var sources: [String] = []
}

enum AIError: LocalizedError {
    case missingKey
    case missingSetting(String)
    case badResponse(Int, String)
    case emptyAnswer
    case unsupportedDevice
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Не указан ключ доступа. Откройте Настройки → ИИ-помощник и подключите сервис."
        case .missingSetting(let name):
            return "Не заполнено поле «\(name)» в настройках сервиса."
        case .badResponse(let code, let message):
            let tail = message.isEmpty ? "" : ": \(message)"
            switch code {
            case 401, 403: return "Сервис отклонил ключ доступа (код \(code))\(tail)"
            case 402: return "На счёте сервиса закончились средства (код 402)\(tail)"
            case 429: return "Слишком много запросов или исчерпан лимит (код 429)\(tail)"
            default: return "Сервис ответил ошибкой (код \(code))\(tail)"
            }
        case .emptyAnswer:
            return "Сервис вернул пустой ответ."
        case .unsupportedDevice:
            return "Встроенная модель работает на iPhone 15 Pro и новее."
        case .modelNotDownloaded:
            return "Встроенная модель ещё не скачана. Скачайте её в Настройках → ИИ-помощник."
        }
    }
}
