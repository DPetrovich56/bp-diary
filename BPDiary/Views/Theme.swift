import SwiftUI
import UIKit

extension BPCategory {
    var color: Color {
        switch self {
        case .low: return Color.indigo
        case .optimal: return Color.green
        case .normal: return Color.teal
        case .highNormal: return Color.yellow
        case .grade1: return Color.orange
        case .grade2: return Color.red
        case .grade3: return Color.purple
        }
    }
}

/// Подпись дня для заголовков списка: «Сегодня», «Вчера» или дата.
enum DayTitle {
    static func text(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, EEEE"
        return formatter.string(from: day)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

/// Строка с данными о погоде.
struct WeatherSummaryView: View {
    let weather: WeatherSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: weather.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: headline)
                    .font(.body)
                Text(verbatim: details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headline: String {
        var parts: [String] = [weather.temperatureTitle]
        if let condition = weather.conditionTitle { parts.append(condition) }
        if let place = weather.place, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: ", ")
    }

    private var details: String {
        var parts: [String] = ["Давление \(weather.pressureTitle)"]
        if let change = weather.pressureChangeTitle { parts.append(change) }
        if let humidity = weather.humidity { parts.append("влажность \(Int(humidity.rounded()))%") }
        if let wind = weather.windSpeed { parts.append("ветер \(Int(wind.rounded())) м/с") }
        return parts.joined(separator: ", ")
    }
}

/// Системное окно «Поделиться» для выгруженного файла.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
