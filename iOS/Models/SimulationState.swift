import CoreLocation
import Foundation

enum SimulationPhase: String, Equatable {
    case idle
    case running
    case paused
    case finished
}

struct SimulatedFix: Equatable {
    var coordinate: CLLocationCoordinate2D
    var course: CLLocationDirection
    var speed: CLLocationSpeed
    var timestamp: Date

    static func == (lhs: SimulatedFix, rhs: SimulatedFix) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.timestamp == rhs.timestamp
    }
}

struct RouteSnapshot: Equatable {
    var name: String
    var coordinates: [CLLocationCoordinate2D]
    var baseSpeed: CLLocationSpeed
    var loops: Bool

    var isRunnable: Bool { coordinates.count > 1 && baseSpeed > 0 }

    var totalDistance: CLLocationDistance { RouteMath.distance(along: coordinates) }

    static func == (lhs: RouteSnapshot, rhs: RouteSnapshot) -> Bool {
        lhs.name == rhs.name
            && lhs.baseSpeed == rhs.baseSpeed
            && lhs.loops == rhs.loops
            && lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }

    init(route: TestRoute) {
        name = route.name
        coordinates = route.coordinates
        baseSpeed = route.baseSpeed
        loops = route.loops
    }
}

struct AppError: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String

    static func == (lhs: AppError, rhs: AppError) -> Bool { lhs.id == rhs.id }
}
