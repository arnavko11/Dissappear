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

/// State of the in-app test session. Nothing here changes system location for
/// other apps — it describes this app's own simulated test environment.
enum SessionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case running
    case paused
    case error(String)

    var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .running: return "Simulation Running"
        case .paused: return "Simulation Paused"
        case .error: return "Error"
        }
    }

    /// State is conveyed by symbol and text as well as colour.
    var symbolName: String {
        switch self {
        case .disconnected: return "circle.dotted"
        case .connecting: return "circle.dashed"
        case .connected: return "checkmark.circle.fill"
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var detail: String? {
        if case let .error(message) = self { return message }
        return nil
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
