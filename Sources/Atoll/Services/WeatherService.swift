import Foundation
import CoreLocation
import SwiftUI

/// Weather glance from Open-Meteo (free, no API key). Location comes from Core Location
/// (asked once) or a city typed in Settings.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    static let shared = WeatherService()

    struct Hour: Codable, Equatable, Identifiable {
        var id: Date { time }
        let time: Date
        let temp: Double
        let code: Int
        let isDay: Bool
    }

    struct Snapshot: Codable, Equatable {
        let temp: Double
        let code: Int
        let isDay: Bool
        let high: Double
        let low: Double
        let place: String
        let updated: Date
        let hours: [Hour]
        let fahrenheit: Bool
    }

    enum Status: Equatable { case off, locating, loading, ready, failed(String) }

    @Published private(set) var status: Status = .off
    @Published private(set) var snapshot: Snapshot?

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var lastPlace = ""

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        snapshot = Storage.load(Snapshot.self, from: "weather.json")
    }

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else {
            status = .off
            return
        }
        refresh()
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let city = Prefs.shared.weatherCity.trimmingCharacters(in: .whitespaces)
        if !city.isEmpty {
            status = .loading
            Task { await geocodeAndFetch(city) }
            return
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            status = .failed("Location off — set a city in Settings")
        case .notDetermined:
            status = .locating
            NSApp.activate()
            manager.requestWhenInUseAuthorization()
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    private func geocodeAndFetch(_ city: String) async {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else {
            status = .failed("Couldn't find “\(city)”")
            return
        }
        lastPlace = first["name"] as? String ?? city
        await fetch(lat: lat, lon: lon)
    }

    private func fetch(lat: Double, lon: Double) async {
        status = .loading
        let f = Prefs.shared.temperatureUnit.usesFahrenheit
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: f ? "fahrenheit" : "celsius"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any] else {
            status = .failed("Weather unavailable")
            return
        }
        let offset = json["utc_offset_seconds"] as? Int ?? 0
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        fmt.timeZone = TimeZone(secondsFromGMT: offset)
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var hours: [Hour] = []
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [Double],
           let codes = hourly["weather_code"] as? [Int],
           let days = hourly["is_day"] as? [Int] {
            let now = Date()
            for i in times.indices where i < temps.count && i < codes.count && i < days.count {
                guard let t = fmt.date(from: times[i]), t > now.addingTimeInterval(-1800) else { continue }
                hours.append(Hour(time: t, temp: temps[i], code: codes[i], isDay: days[i] == 1))
                if hours.count == 6 { break }
            }
        }
        let snap = Snapshot(temp: current["temperature_2m"] as? Double ?? 0,
                            code: current["weather_code"] as? Int ?? 0,
                            isDay: (current["is_day"] as? Int ?? 1) == 1,
                            high: (daily["temperature_2m_max"] as? [Double])?.first ?? 0,
                            low: (daily["temperature_2m_min"] as? [Double])?.first ?? 0,
                            place: lastPlace,
                            updated: Date(),
                            hours: hours,
                            fahrenheit: f)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            snapshot = snap
            status = .ready
        }
        Storage.save(snap, to: "weather.json")
    }

    #if DEBUG
    func debugSet(_ s: Snapshot) {
        snapshot = s
        status = .ready
    }
    #endif

    // MARK: - WMO weather codes

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: "cloud.heavyrain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Storm with hail"
        default: "—"
        }
    }

    static func tint(_ code: Int, day: Bool) -> Color {
        switch code {
        case 0: day ? .yellow : .indigo
        case 1, 2: day ? .orange : .indigo
        case 61...67, 80...82: .cyan
        case 71...77, 85, 86: .white
        case 95...99: .purple
        default: .gray
        }
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard Prefs.shared.weatherEnabled, Prefs.shared.weatherCity.isEmpty else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorized: manager.requestLocation()
            case .denied, .restricted: self.status = .failed("Location off — set a city in Settings")
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let place = try? await CLGeocoder().reverseGeocodeLocation(loc).first
            self.lastPlace = place?.locality ?? place?.name ?? ""
            await self.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.snapshot == nil { self.status = .failed("Location unavailable — set a city in Settings") }
        }
    }
}
