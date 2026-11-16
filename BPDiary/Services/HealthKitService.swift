import Foundation
import HealthKit

/// Замер давления, прочитанный из «Здоровья» (записан другим приложением или прибором).
struct HealthReading {
    let uuid: UUID
    let date: Date
    let systolic: Int
    let diastolic: Int
    let pulse: Int?
    let sourceName: String
}

enum HealthError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Приложение «Здоровье» недоступно на этом устройстве."
        }
    }
}

/// Обмен данными со штатным приложением «Здоровье» (HealthKit).
final class HealthKitService: @unchecked Sendable {
    static let shared = HealthKitService()

    /// Ключ метаданных, по которому приложение находит свои образцы в «Здоровье».
    static let entryIDKey = "BPDiaryEntryID"

    private let store = HKHealthStore()

    private let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!
    private let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let pressureType = HKObjectType.correlationType(forIdentifier: .bloodPressure)!

    private let mmHg = HKUnit.millimeterOfMercury()
    private let beatsPerMinute = HKUnit.count().unitDivided(by: HKUnit.minute())

    private init() {}

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var canWriteBloodPressure: Bool {
        guard isAvailable else { return false }
        return store.authorizationStatus(for: systolicType) == .sharingAuthorized
            && store.authorizationStatus(for: diastolicType) == .sharingAuthorized
    }

    private var canWriteHeartRate: Bool {
        store.authorizationStatus(for: heartRateType) == .sharingAuthorized
    }

    /// Запрашивает доступ на чтение и запись давления и пульса.
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthError.unavailable }
        let share: Set<HKSampleType> = [systolicType, diastolicType, heartRateType]
        let read: Set<HKObjectType> = [systolicType, diastolicType, heartRateType]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Запись

    func save(entry: BPEntry) async throws {
        guard isAvailable else { throw HealthError.unavailable }

        let metadata: [String: Any] = [
            HealthKitService.entryIDKey: entry.id.uuidString,
            HKMetadataKeyWasUserEntered: true
        ]

        let systolic = HKQuantitySample(
            type: systolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: Double(entry.systolic)),
            start: entry.date,
            end: entry.date,
            metadata: metadata
        )
        let diastolic = HKQuantitySample(
            type: diastolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: Double(entry.diastolic)),
            start: entry.date,
            end: entry.date,
            metadata: metadata
        )
        let parts: Set<HKSample> = [systolic, diastolic]
        let correlation = HKCorrelation(
            type: pressureType,
            start: entry.date,
            end: entry.date,
            objects: parts,
            metadata: metadata
        )

        var objects: [HKObject] = [correlation]
        if let pulse = entry.pulse, canWriteHeartRate {
            let heartRate = HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: beatsPerMinute, doubleValue: Double(pulse)),
                start: entry.date,
                end: entry.date,
                metadata: metadata
            )
            objects.append(heartRate)
        }
        try await store.save(objects)
    }

    // MARK: - Удаление

    /// Удаляет из «Здоровья» образцы, записанные этим приложением для указанной записи дневника.
    func delete(entryID: UUID) async throws {
        guard isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HealthKitService.entryIDKey,
            allowedValues: [entryID.uuidString]
        )

        let correlations = try await samples(of: pressureType, predicate: predicate)
        if !correlations.isEmpty {
            try await store.delete(correlations)
        }

        // Если после удаления корреляции остались отдельные образцы — убираем и их.
        var leftovers: [HKObject] = []
        for type in [systolicType, diastolicType, heartRateType] {
            let found = try await samples(of: type, predicate: predicate)
            leftovers.append(contentsOf: found)
        }
        if !leftovers.isEmpty {
            try await store.delete(leftovers)
        }
    }

    // MARK: - Чтение

    /// Возвращает замеры давления, записанные в «Здоровье» другими приложениями и приборами.
    func readExternalReadings(since: Date) async throws -> [HealthReading] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let found = try await samples(of: pressureType, predicate: predicate)
        let ownBundle = Bundle.main.bundleIdentifier

        var external: [HKCorrelation] = []
        for sample in found {
            guard let correlation = sample as? HKCorrelation else { continue }
            if correlation.sourceRevision.source.bundleIdentifier == ownBundle { continue }
            external.append(correlation)
        }
        guard !external.isEmpty else { return [] }

        // Пульс ищем среди образцов того же источника, записанных в пределах двух минут от замера.
        let heartRates = (try? await samples(of: heartRateType, predicate: predicate)) ?? []

        var result: [HealthReading] = []
        for correlation in external {
            guard
                let systolicSample = correlation.objects(for: systolicType).first as? HKQuantitySample,
                let diastolicSample = correlation.objects(for: diastolicType).first as? HKQuantitySample
            else { continue }

            let source = correlation.sourceRevision.source
            var pulse: Int?
            var bestGap: TimeInterval = 120
            for sample in heartRates {
                guard
                    let heartRate = sample as? HKQuantitySample,
                    heartRate.sourceRevision.source.bundleIdentifier == source.bundleIdentifier
                else { continue }
                let gap = abs(heartRate.startDate.timeIntervalSince(correlation.startDate))
                if gap <= bestGap {
                    bestGap = gap
                    pulse = Int(heartRate.quantity.doubleValue(for: beatsPerMinute).rounded())
                }
            }

            result.append(
                HealthReading(
                    uuid: correlation.uuid,
                    date: correlation.startDate,
                    systolic: Int(systolicSample.quantity.doubleValue(for: mmHg).rounded()),
                    diastolic: Int(diastolicSample.quantity.doubleValue(for: mmHg).rounded()),
                    pulse: pulse,
                    sourceName: source.name
                )
            )
        }
        return result
    }

    private func samples(of type: HKSampleType, predicate: NSPredicate?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results ?? [])
                }
            }
            store.execute(query)
        }
    }
}
