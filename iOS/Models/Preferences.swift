import MapKit
import SwiftUI

enum PreferenceKey {
    static let mapStyle = "preference.mapStyle"
    static let defaultSpeed = "preference.defaultSpeed"
    static let distanceUnit = "preference.distanceUnit"
    static let appearance = "preference.appearance"
    static let updateFrequency = "preference.updateFrequency"
    static let smoothMarker = "preference.smoothMarker"
    static let lastLatitude = "preference.lastLatitude"
    static let lastLongitude = "preference.lastLongitude"
    static let didSeedLibrary = "preference.didSeedLibrary"
}

enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .hybrid: return "Hybrid"
        case .imagery: return "Satellite"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .hybrid: return "globe.americas"
        case .imagery: return "globe"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        case .imagery: return .imagery(elevation: .realistic)
        }
    }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case automatic
    case metric
    case imperial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }
}

enum AppearanceOption: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SimulationSpeed: Double, CaseIterable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case normal = 1
    case double = 2
    case quintuple = 5
    case tenfold = 10

    var id: Double { rawValue }

    var title: String {
        rawValue < 1 ? "\(rawValue.formatted(.number.precision(.fractionLength(0...2))))×" : "\(Int(rawValue))×"
    }

    static func nearest(to value: Double) -> SimulationSpeed {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .normal
    }
}

struct MeasurementFormatting {
    var unit: DistanceUnit

    func distance(_ metres: Double) -> String {
        let measurement = Measurement(value: metres, unit: UnitLength.meters)
        switch unit {
        case .automatic:
            return measurement.formatted(.measurement(width: .abbreviated, usage: .road))
        case .metric:
            let converted = metres >= 1000 ? measurement.converted(to: .kilometers) : measurement
            return converted.formatted(.measurement(width: .abbreviated,
                                                    usage: .asProvided,
                                                    numberFormatStyle: .number.precision(.fractionLength(0...2))))
        case .imperial:
            let miles = measurement.converted(to: .miles)
            let feet = measurement.converted(to: .feet)
            let converted = miles.value >= 0.1 ? miles : feet
            return converted.formatted(.measurement(width: .abbreviated,
                                                    usage: .asProvided,
                                                    numberFormatStyle: .number.precision(.fractionLength(0...2))))
        }
    }

    func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds],
                                                          width: .abbreviated,
                                                          maximumUnitCount: 2))
    }
}
