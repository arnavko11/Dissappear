import CoreLocation
import Foundation
import SwiftData

@Model
final class TestRoute {
    var name: String
    /// Base travel speed in metres per second before the simulation multiplier.
    var baseSpeed: Double
    var loops: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RouteWaypoint.route)
    var waypoints: [RouteWaypoint] = []

    init(name: String, baseSpeed: Double = 13.9, loops: Bool = false, createdAt: Date = .now) {
        self.name = name
        self.baseSpeed = baseSpeed
        self.loops = loops
        self.createdAt = createdAt
    }

    var orderedWaypoints: [RouteWaypoint] {
        waypoints.sorted { $0.order < $1.order }
    }

    var coordinates: [CLLocationCoordinate2D] {
        orderedWaypoints.map(\.coordinate)
    }

    var totalDistance: CLLocationDistance {
        RouteMath.distance(along: coordinates)
    }

    /// Estimated duration at 1× speed.
    var estimatedDuration: TimeInterval {
        guard baseSpeed > 0 else { return 0 }
        return totalDistance / baseSpeed
    }

    func appendWaypoint(name: String, coordinate: CLLocationCoordinate2D) {
        let waypoint = RouteWaypoint(name: name,
                                     latitude: coordinate.latitude,
                                     longitude: coordinate.longitude,
                                     order: (waypoints.map(\.order).max() ?? -1) + 1)
        waypoint.route = self
        waypoints.append(waypoint)
    }

    func reverse() {
        let ordered = orderedWaypoints
        for (index, waypoint) in ordered.reversed().enumerated() {
            waypoint.order = index
        }
    }

    func normalizeOrder() {
        for (index, waypoint) in orderedWaypoints.enumerated() {
            waypoint.order = index
        }
    }
}

@Model
final class RouteWaypoint {
    var name: String
    var latitude: Double
    var longitude: Double
    var order: Int
    var route: TestRoute?

    init(name: String, latitude: Double, longitude: Double, order: Int) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.order = order
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteMath {
    static func distance(along coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func interpolate(from start: CLLocationCoordinate2D,
                            to end: CLLocationCoordinate2D,
                            fraction: Double) -> CLLocationCoordinate2D {
        let t = min(max(fraction, 0), 1)

        // The short way round the date line: -179 to 179 is two degrees east,
        // not 358 degrees west across the whole globe.
        var deltaLongitude = end.longitude - start.longitude
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }

        var longitude = start.longitude + deltaLongitude * t
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }

        return CLLocationCoordinate2D(latitude: start.latitude + (end.latitude - start.latitude) * t,
                                      longitude: longitude)
    }

    static func course(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
