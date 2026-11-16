import Foundation

enum WeatherError: LocalizedError {
    case tooOld
    case noCity
    case noData
    case badResponse

    var errorDescription: String? {
        switch self {
        case .tooOld: return "Погода доступна только для замеров за последние три месяца."
        case .noCity: return "Город не выбран. Укажите его в настройках."
        case .noData: return "Сервис погоды не вернул данные для этого времени."
        case .badResponse: return "Сервис погоды временно недоступен."
        }
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

/// Погода по данным Open-Meteo (https://open-meteo.com), лицензия CC BY 4.0.
struct WeatherService: Sendable {
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

    private struct GeocodingResponse: Decodable {
        struct Item: Decodable {
            let id: Int
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Item]?
    }

    /// Коэффициент перевода гектопаскалей в миллиметры ртутного столба.
    private static let hPaToMmHg = 0.750062

    /// Погода в указанной точке на момент `date` (ближайший час).
    func fetch(latitude: Double, longitude: Double, date: Date, place: String?) async throws -> WeatherSnapshot {
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
            throw WeatherError.badResponse
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
        guard let url = components.url else { throw WeatherError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherError.badResponse
        }
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

    /// Поиск города по названию.
    func searchCity(_ name: String) async throws -> [CityResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else {
            throw WeatherError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "ru"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw WeatherError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherError.badResponse
        }
        let decoded = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        return (decoded.results ?? []).map { item in
            let region = [item.admin1, item.country]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return CityResult(
                id: item.id,
                name: item.name,
                region: region,
                latitude: item.latitude,
                longitude: item.longitude
            )
        }
    }
}
