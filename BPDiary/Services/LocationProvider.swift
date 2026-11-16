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
