import Foundation
import CoreLocation

enum LocationError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Нет доступа к геопозиции. Разрешите его в Настройках или выберите город вручную."
        }
    }
}

/// Разовое определение примерного местоположения для запроса погоды.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Запрашивает разрешение на геопозицию (системное окно показывается один раз).
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation() async throws -> CLLocation {
        if isDenied { throw LocationError.denied }

        if let last = manager.location, abs(last.timestamp.timeIntervalSinceNow) < 900 {
            return last
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            waiting.append(continuation)
            if waiting.count == 1 {
                if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    manager.requestLocation()
                }
            }
        }
    }

    /// Поиск города по названию через геокодер Apple (работает без сторонних сервисов).
    func searchCity(_ name: String) async throws -> [CityResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let geocoder = CLGeocoder()
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await geocoder.geocodeAddressString(trimmed)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return []
        }
        var results: [CityResult] = []
        var seen = Set<String>()
        for (index, placemark) in placemarks.enumerated() {
            guard let location = placemark.location else { continue }
            let title = placemark.locality ?? placemark.name ?? trimmed
            let region = [placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
                .filter { !$0.isEmpty && $0 != title }
                .joined(separator: ", ")
            let key = title + "|" + region
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(
                CityResult(
                    id: index,
                    name: title,
                    region: region,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            )
        }
        return results
    }

    /// Название населённого пункта для подписи к погоде.
    func placeName(for location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        return placemarks?.first?.locality ?? placemarks?.first?.administrativeArea
    }

    private func finish(with result: Result<CLLocation, Error>) {
        let pending = waiting
        waiting = []
        for continuation in pending {
            continuation.resume(with: result)
        }
    }

    private func authorizationChanged() {
        guard !waiting.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: .failure(LocationError.denied))
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationChanged()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.finish(with: .success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }
}
