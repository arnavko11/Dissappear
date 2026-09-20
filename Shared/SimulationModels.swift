import Foundation

public struct SimulatedCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public init(latitude: Double, longitude: Double, altitude: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct SimulatedLocation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String
    public var coordinate: SimulatedCoordinate

    public init(id: UUID = UUID(), name: String, note: String = "", coordinate: SimulatedCoordinate) {
        self.id = id
        self.name = name
        self.note = note
        self.coordinate = coordinate
    }
}

public struct SimulatedRoute: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var waypoints: [SimulatedCoordinate]
    /// Metres per second used when replaying the route.
    public var speed: Double
    public var loops: Bool

    public init(id: UUID = UUID(), name: String, waypoints: [SimulatedCoordinate], speed: Double = 11, loops: Bool = false) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.speed = speed
        self.loops = loops
    }
}

public struct SimulationScenario: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fixed
        case route
    }

    public var id: UUID
    public var name: String
    public var summary: String
    public var kind: Kind
    public var locationID: UUID?
    public var routeID: UUID?
    /// Horizontal accuracy reported by the simulated provider, in metres.
    public var horizontalAccuracy: Double
    /// Interval between simulated updates, in seconds.
    public var updateInterval: Double

    public init(id: UUID = UUID(),
                name: String,
                summary: String = "",
                kind: Kind,
                locationID: UUID? = nil,
                routeID: UUID? = nil,
                horizontalAccuracy: Double = 5,
                updateInterval: Double = 1) {
        self.id = id
        self.name = name
        self.summary = summary
        self.kind = kind
        self.locationID = locationID
        self.routeID = routeID
        self.horizontalAccuracy = horizontalAccuracy
        self.updateInterval = updateInterval
    }
}

public struct SimulationLibrary: Codable, Hashable, Sendable {
    public static let resourceName = "SimulationLibrary"

    public var locations: [SimulatedLocation]
    public var routes: [SimulatedRoute]
    public var scenarios: [SimulationScenario]

    public init(locations: [SimulatedLocation] = [], routes: [SimulatedRoute] = [], scenarios: [SimulationScenario] = []) {
        self.locations = locations
        self.routes = routes
        self.scenarios = scenarios
    }

    public func location(with id: UUID?) -> SimulatedLocation? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }

    public func route(with id: UUID?) -> SimulatedRoute? {
        guard let id else { return nil }
        return routes.first { $0.id == id }
    }

    public static var sample: SimulationLibrary {
        let ferry = SimulatedLocation(name: "Ferry Building",
                                      note: "San Francisco waterfront",
                                      coordinate: .init(latitude: 37.7955, longitude: -122.3937, altitude: 4))
        let park = SimulatedLocation(name: "Dolores Park",
                                     note: "Elevated park, good GPS shadowing",
                                     coordinate: .init(latitude: 37.7596, longitude: -122.4269, altitude: 70))
        let route = SimulatedRoute(name: "Embarcadero Run",
                                   waypoints: [
                                       .init(latitude: 37.7955, longitude: -122.3937),
                                       .init(latitude: 37.8005, longitude: -122.3985),
                                       .init(latitude: 37.8066, longitude: -122.4030),
                                       .init(latitude: 37.8087, longitude: -122.4098)
                                   ],
                                   speed: 3.5,
                                   loops: true)
        return SimulationLibrary(
            locations: [ferry, park],
            routes: [route],
            scenarios: [
                SimulationScenario(name: "Stationary — Ferry Building",
                                   summary: "Fixed coordinate with tight accuracy",
                                   kind: .fixed,
                                   locationID: ferry.id),
                SimulationScenario(name: "Jog — Embarcadero",
                                   summary: "Looping route replay at 3.5 m/s",
                                   kind: .route,
                                   routeID: route.id,
                                   horizontalAccuracy: 8)
            ])
    }
}

public enum GeoMath {
    static let earthRadius: Double = 6_372_797.6

    public static func distance(_ a: SimulatedCoordinate, _ b: SimulatedCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    public static func interpolate(_ a: SimulatedCoordinate, _ b: SimulatedCoordinate, fraction: Double) -> SimulatedCoordinate {
        let t = max(0, min(1, fraction))
        return SimulatedCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                   longitude: a.longitude + (b.longitude - a.longitude) * t,
                                   altitude: a.altitude + (b.altitude - a.altitude) * t)
    }

    public static func course(from a: SimulatedCoordinate, to b: SimulatedCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
