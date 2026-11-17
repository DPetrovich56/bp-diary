import Foundation

enum WeatherError: LocalizedError {
    case tooOld
    case noCity
    case noData
    case badResponse(Int)
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .tooOld: return "Погода доступна только для замеров за последние три месяца."
        case .noCity: return "Город не выбран. Укажите его в настройках."
        case .noData: return "Нет данных для этого времени."
        case .badResponse(let code): return "Сервер ответил с ошибкой (код \(code))."
        case .allSourcesFailed(let lines): return lines.joined(separator: "\n")
        }
    }
}

/// Источник данных о погоде.
enum WeatherProvider: String, CaseIterable, Sendable {
    case openMeteo = "Open-Meteo"
    case metNorway = "MET Norway"
}

/// Перевод давления на уровне моря в давление на уровне местности (барометрическая формула).
enum PressureMath {
    static func stationPressure(seaLevel hPa: Double, elevation meters: Double, temperature celsius: Double) -> Double {
        guard meters > 0 else { return hPa }
        let ratio = 0.0065 * meters / (celsius + 0.0065 * meters + 273.15)
        return hPa * pow(1 - ratio, 5.257)
    }
}

struct CityResult: Identifiable, Hashable {
    let id: Int
    let name: String
    let region: String
    let latitude: Double
    let longitude: Double

    var subtitle: String { region }
}

/// Погода из открытых источников: сначала Open-Meteo (https://open-meteo.com),
/// при неудаче — MET Norway (https://api.met.no). Данные обоих — по лицензии CC BY 4.0.
struct WeatherService: Sendable {
    /// Подпись приложения в запросах: MET Norway без неё отвечает отказом.
    static let userAgent = "BPDiary/1.0 github.com/DPetrovich56/bp-diary"

    /// Пробует источники по очереди и возвращает первый удачный результат.
    func fetch(latitude: Double, longitude: Double, date: Date, place: String?) async throws -> WeatherSnapshot {
        var failures: [String] = []
        for provider in WeatherProvider.allCases {
            do {
                return try await fetch(from: provider, latitude: latitude, longitude: longitude, date: date, place: place)
            } catch {
                failures.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw WeatherError.allSourcesFailed(failures)
    }

    func fetch(
        from provider: WeatherProvider,
        latitude: Double,
        longitude: Double,
        date: Date,
        place: String?
    ) async throws -> WeatherSnapshot {
        switch provider {
        case .openMeteo:
            return try await fetchOpenMeteo(latitude: latitude, longitude: longitude, date: date, place: place)
        case .metNorway:
            return try await fetchMetNorway(latitude: latitude, longitude: longitude, date: date, place: place)
        }
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(WeatherService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherError.badResponse(0) }
        guard http.statusCode == 200 else { throw WeatherError.badResponse(http.statusCode) }
        return data
    }

    private struct ForecastResponse: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let relative_humidity_2m: [Double?]?
            let surface_pressure: [Double?]
            let weather_code: [Double?]?
            let wind_speed_10m: [Double?]?
        }
        let hourly: Hourly
    }

    /// Коэффициент перевода гектопаскалей в миллиметры ртутного столба.
    private static let hPaToMmHg = 0.750062

    // MARK: - Open-Meteo

    private func fetchOpenMeteo(latitude: Double, longitude: Double, date: Date, place: String?) async throws -> WeatherSnapshot {
        let now = Date()
        guard date > now.addingTimeInterval(-89 * 86_400) else { throw WeatherError.tooOld }
        let moment = min(date, now.addingTimeInterval(3 * 86_400))

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"

        // Берём сутки до и сутки после, чтобы найти ближайший час и давление 24 часа назад.
        let startDay = formatter.string(from: moment.addingTimeInterval(-86_400))
        let endDay = formatter.string(from: moment.addingTimeInterval(86_400))

        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            throw WeatherError.badResponse(0)
        }
        components.queryItems = [
            // Координаты округляем до ~1 км: точнее для погоды не нужно.
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,relative_humidity_2m,surface_pressure,weather_code,wind_speed_10m"
            ),
            URLQueryItem(name: "start_date", value: startDay),
            URLQueryItem(name: "end_date", value: endDay),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "wind_speed_unit", value: "ms")
        ]
        guard let url = components.url else { throw WeatherError.badResponse(0) }

        let data = try await load(url)
        let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let hourly = decoded.hourly

        let target = moment.timeIntervalSince1970
        var bestIndex: Int?
        var bestGap = Double.greatestFiniteMagnitude
        for index in hourly.time.indices {
            guard
                index < hourly.temperature_2m.count, hourly.temperature_2m[index] != nil,
                index < hourly.surface_pressure.count, hourly.surface_pressure[index] != nil
            else { continue }
            let gap = abs(hourly.time[index] - target)
            if gap < bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        guard
            let index = bestIndex,
            bestGap <= 3 * 3_600,
            let temperature = hourly.temperature_2m[index],
            let pressureHPa = hourly.surface_pressure[index]
        else { throw WeatherError.noData }

        let pressure = pressureHPa * WeatherService.hPaToMmHg

        // Давление сутки назад — для оценки перепада.
        var change: Double?
        let dayAgo = hourly.time[index] - 86_400
        if let previousIndex = hourly.time.firstIndex(where: { abs($0 - dayAgo) < 1_800 }),
           previousIndex < hourly.surface_pressure.count,
           let previous = hourly.surface_pressure[previousIndex] {
            change = pressure - previous * WeatherService.hPaToMmHg
        }

        func value(_ list: [Double?]?) -> Double? {
            guard let list, index < list.count else { return nil }
            return list[index]
        }

        return WeatherSnapshot(
            temperature: temperature,
            pressureMmHg: pressure,
            pressureChange24h: change,
            humidity: value(hourly.relative_humidity_2m),
            windSpeed: value(hourly.wind_speed_10m),
            weatherCode: value(hourly.weather_code).map { Int($0) },
            place: place
        )
    }

    // MARK: - MET Norway

    private struct MetResponse: Decodable {
        struct Geometry: Decodable {
            let coordinates: [Double]
        }
        struct Properties: Decodable {
            let timeseries: [Step]
        }
        struct Step: Decodable {
            let time: String
            let data: StepData
        }
        struct StepData: Decodable {
            let instant: Instant
            let next_1_hours: Period?
            let next_6_hours: Period?
        }
        struct Instant: Decodable {
            let details: Details
        }
        struct Details: Decodable {
            let air_pressure_at_sea_level: Double?
            let air_temperature: Double?
            let relative_humidity: Double?
            let wind_speed: Double?
        }
        struct Period: Decodable {
            let summary: Summary?
        }
        struct Summary: Decodable {
            let symbol_code: String?
        }
        let geometry: Geometry?
        let properties: Properties
    }

    /// MET Norway даёт прогноз от текущего часа вперёд, поэтому подходит для свежих замеров.
    private func fetchMetNorway(latitude: Double, longitude: Double, date: Date, place: String?) async throws -> WeatherSnapshot {
        guard var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact") else {
            throw WeatherError.badResponse(0)
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.2f", longitude))
        ]
        guard let url = components.url else { throw WeatherError.badResponse(0) }

        let data = try await load(url)
        let decoded = try JSONDecoder().decode(MetResponse.self, from: data)

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]

        var best: (gap: TimeInterval, step: MetResponse.Step)?
        for step in decoded.properties.timeseries {
            guard let time = parser.date(from: step.time) else { continue }
            let gap = abs(time.timeIntervalSince(date))
            if best == nil || gap < best!.gap {
                best = (gap, step)
            }
        }
        guard let found = best, found.gap <= 2 * 3_600 else {
            // Прошедшее время этот источник не покрывает.
            throw WeatherError.noData
        }
        let details = found.step.data.instant.details
        guard let temperature = details.air_temperature, let seaLevel = details.air_pressure_at_sea_level else {
            throw WeatherError.noData
        }

        let elevation: Double = {
            guard let coordinates = decoded.geometry?.coordinates, coordinates.count >= 3 else { return 0 }
            return coordinates[2]
        }()
        let station = PressureMath.stationPressure(seaLevel: seaLevel, elevation: elevation, temperature: temperature)
        let symbol = found.step.data.next_1_hours?.summary?.symbol_code
            ?? found.step.data.next_6_hours?.summary?.symbol_code

        return WeatherSnapshot(
            temperature: temperature,
            pressureMmHg: station * WeatherService.hPaToMmHg,
            pressureChange24h: nil,
            humidity: details.relative_humidity,
            windSpeed: details.wind_speed,
            weatherCode: symbol.map(WeatherService.wmoCode(fromMetSymbol:)),
            place: place
        )
    }

    /// Перевод условного обозначения MET Norway в код погоды WMO, которым пользуется приложение.
    static func wmoCode(fromMetSymbol raw: String) -> Int {
        let symbol = raw.split(separator: "_").first.map(String.init) ?? raw
        if symbol.contains("thunder") { return 95 }
        if symbol.contains("sleet") { return WeatherSnapshot.sleetCode }
        if symbol.contains("snow") {
            if symbol.hasPrefix("light") { return 71 }
            if symbol.hasPrefix("heavy") { return 75 }
            return 73
        }
        if symbol.contains("rain") {
            if symbol.contains("showers") { return 80 }
            if symbol.hasPrefix("light") { return 61 }
            if symbol.hasPrefix("heavy") { return 65 }
            return 63
        }
        switch symbol {
        case "clearsky": return 0
        case "fair": return 1
        case "partlycloudy": return 2
        case "cloudy": return 3
        case "fog": return 45
        default: return 3
        }
    }
}
