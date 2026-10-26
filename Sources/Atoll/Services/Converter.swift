import Foundation

/// Natural-language conversions for the launcher: units, currency, time zones, percentages.
struct Conversion: Equatable {
    let output: String      // what gets copied
    let display: String     // big text
    let detail: String      // caption
    let symbol: String
}

@MainActor
enum Converter {
    static func convert(_ raw: String) -> Conversion? {
        let q = raw.trimmingCharacters(in: .whitespaces)
        return percent(q) ?? units(q) ?? currency(q) ?? timeIn(q)
    }

    // MARK: - Number formatting

    static func format(_ v: Double, maxFraction: Int = 4) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) >= 1000 ? 2 : maxFraction
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ""))
    }

    /// Patterns compile once, not on every keystroke in search.
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let hit = compiled.object(forKey: pattern as NSString) { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        compiled.setObject(re, forKey: pattern as NSString)
        return re
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = regex(pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    // MARK: - Percent

    private static func percent(_ q: String) -> Conversion? {
        guard let m = match(#"^([\d.,]+)\s*%\s*(?:of)\s*([\d.,]+)$"#, q),
              let p = number(m[1]), let base = number(m[2]) else { return nil }
        let v = base * p / 100
        return Conversion(output: format(v), display: format(v), detail: "\(m[1])% of \(m[2])", symbol: "percent")
    }

    // MARK: - Units

    private static let days = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let weeks = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    private static let unitTable: [String: Dimension] = {
        var t: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { names.forEach { t[$0] = unit } }
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters")
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.feet, "ft", "foot", "feet")
        add(UnitLength.inches, "in", "inch", "inches", "\"")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile", "nautical miles")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.milligrams, "mg", "milligram", "milligrams")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.stones, "st", "stone", "stones")
        add(UnitMass.metricTons, "t", "tonne", "tonnes", "ton", "tons")
        add(UnitTemperature.celsius, "c", "°c", "celsius", "degc")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit", "degf")
        add(UnitTemperature.kelvin, "k", "kelvin")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.pints, "pt", "pint", "pints")
        add(UnitVolume.cups, "cup", "cups")
        add(UnitVolume.fluidOunces, "floz", "fl oz", "fluid ounce", "fluid ounces")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon", "tablespoons")
        add(UnitVolume.teaspoons, "tsp", "teaspoon", "teaspoons")
        add(UnitSpeed.kilometersPerHour, "kmh", "km/h", "kph")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.knots, "kn", "knot", "knots")
        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        add(days, "d", "day", "days")
        add(weeks, "wk", "week", "weeks")
        add(UnitInformationStorage.bytes, "b", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte", "kilobytes")
        add(UnitInformationStorage.megabytes, "mb", "megabyte", "megabytes")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte", "gigabytes")
        add(UnitInformationStorage.terabytes, "tb", "terabyte", "terabytes")
        add(UnitInformationStorage.megabits, "mbit", "mbps", "megabit", "megabits")
        add(UnitInformationStorage.gigabits, "gbit", "gbps", "gigabit", "gigabits")
        add(UnitArea.squareMeters, "m2", "m²", "sqm", "square meters")
        add(UnitArea.squareKilometers, "km2", "km²")
        add(UnitArea.squareFeet, "ft2", "ft²", "sqft", "square feet")
        add(UnitArea.acres, "acre", "acres", "ac")
        add(UnitArea.hectares, "ha", "hectare", "hectares")
        add(UnitEnergy.kilocalories, "kcal", "calorie", "calories", "cal")
        add(UnitEnergy.kilojoules, "kj", "kilojoule", "kilojoules")
        add(UnitEnergy.kilowattHours, "kwh")
        add(UnitAngle.degrees, "deg", "degree", "degrees", "°")
        add(UnitAngle.radians, "rad", "radian", "radians")
        return t
    }()

    private static func units(_ q: String) -> Conversion? {
        guard let m = match(#"^(-?[\d.,]+)\s*([a-z°²/" ]+?)\s+(?:to|in|as|into|->|=)\s+([a-z°²/" ]+?)$"#, q),
              let v = number(m[1]),
              let from = unitTable[m[2].lowercased().trimmingCharacters(in: .whitespaces)],
              let to = unitTable[m[3].lowercased().trimmingCharacters(in: .whitespaces)],
              type(of: from) == type(of: to) else { return nil }
        let result = Measurement(value: v, unit: from).converted(to: to).value
        let out = format(result)
        return Conversion(output: out, display: "\(out) \(to.symbol)", detail: "\(format(v)) \(from.symbol) → \(to.symbol)", symbol: "arrow.left.arrow.right")
    }

    // MARK: - Currency

    private static let currencySymbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₽": "RUB"]

    private static func currencyCode(_ s: String) -> String? {
        if let c = currencySymbols[s] { return c }
        let up = s.uppercased()
        return up.count == 3 && Locale.commonISOCurrencyCodes.contains(up) ? up : nil
    }

    private static func currency(_ q: String) -> Conversion? {
        guard Prefs.shared.onlineCurrency,
              let m = match(#"^([$€£¥₹₩₽]|[a-z]{3})?\s*([\d.,]+)\s*([a-z]{3}|[$€£¥₹₩₽])?\s+(?:to|in|as)\s+([a-z]{3}|[$€£¥₹₩₽])$"#, q),
              let amount = number(m[2]),
              let from = currencyCode(m[1].isEmpty ? m[3] : m[1]),
              let to = currencyCode(m[4]), from != to else { return nil }
        guard let rate = CurrencyRates.shared.rate(from: from, to: to) else {
            return Conversion(output: "", display: "Fetching rates…", detail: "\(from) → \(to)", symbol: "dollarsign.arrow.circlepath")
        }
        let v = amount * rate
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = to
        let shown = f.string(from: NSNumber(value: v)) ?? format(v, maxFraction: 2)
        return Conversion(output: format(v, maxFraction: 2), display: shown,
                          detail: "\(format(amount, maxFraction: 2)) \(from) · 1 \(from) = \(format(rate)) \(to) · ECB rates",
                          symbol: "dollarsign.arrow.circlepath")
    }

    // MARK: - Time zones

    private static let zoneAliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York", "sf": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata", "kochi": "Asia/Kolkata",
        "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "japan": "Asia/Tokyo", "uk": "Europe/London",
        "germany": "Europe/Berlin", "france": "Europe/Paris", "boston": "America/New_York", "miami": "America/New_York",
        "austin": "America/Chicago", "dallas": "America/Chicago", "utc": "UTC", "gmt": "GMT",
    ]

    private static let cityZones: [String: String] = {
        var map: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            if let city = id.split(separator: "/").last {
                map[city.replacingOccurrences(of: "_", with: " ").lowercased()] = id
            }
        }
        return map
    }()

    private static func timeIn(_ q: String) -> Conversion? {
        let lower = q.lowercased()
        let place: String
        if let m = match(#"^(?:time|what time is it)\s+(?:in|at)\s+(.+)$"#, lower) {
            place = m[1]
        } else if let m = match(#"^(.+?)\s+time$"#, lower) {
            place = m[1]
        } else {
            return nil
        }
        let key = place.trimmingCharacters(in: .whitespaces)
        guard let zone = zoneAliases[key].flatMap(TimeZone.init(identifier:))
                ?? cityZones[key].flatMap(TimeZone.init(identifier:))
                ?? TimeZone(abbreviation: key.uppercased()) else { return nil }
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "h:mm a"
        let day = DateFormatter()
        day.timeZone = zone
        day.dateFormat = "EEEE"
        let diff = zone.secondsFromGMT() - TimeZone.current.secondsFromGMT()
        let h = abs(diff) / 3600, m = (abs(diff) % 3600) / 60
        let rel = diff == 0 ? "same time as here" : "\(diff > 0 ? "+" : "−")\(h)h\(m > 0 ? " \(m)m" : "") from here"
        let now = Date()
        return Conversion(output: f.string(from: now), display: f.string(from: now),
                          detail: "\(key.capitalized) · \(day.string(from: now)) · \(rel)", symbol: "globe.americas.fill")
    }
}

/// ECB reference rates via frankfurter (free, no key), cached for 6 hours.
@MainActor
final class CurrencyRates: ObservableObject {
    static let shared = CurrencyRates()

    @Published private(set) var version = 0
    private var tables: [String: (rates: [String: Double], fetched: Date)] = [:]
    private var inFlight = Set<String>()

    func rate(from: String, to: String) -> Double? {
        if let t = tables[from], Date().timeIntervalSince(t.fetched) < 6 * 3600 {
            return t.rates[to]
        }
        fetch(base: from)
        return nil
    }

    private func fetch(base: String) {
        guard !inFlight.contains(base) else { return }
        inFlight.insert(base)
        Task {
            defer { inFlight.remove(base) }
            for endpoint in ["https://api.frankfurter.dev/v1/latest?base=\(base)", "https://api.frankfurter.app/latest?from=\(base)"] {
                guard let url = URL(string: endpoint),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rates = json["rates"] as? [String: Double] else { continue }
                tables[base] = (rates, Date())
                version += 1
                return
            }
        }
    }
}
