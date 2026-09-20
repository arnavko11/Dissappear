import CoreLocation
import Observation
import SwiftData

/// Editing operations for a route. Mutations go straight to the SwiftData
/// model; this type keeps ordering and validation in one place.
@MainActor
@Observable
final class RouteEditorViewModel {
    private(set) var lastError: AppError?

    func addWaypoint(to route: TestRoute, name: String, coordinate: CLLocationCoordinate2D, context: ModelContext) {
        guard RouteMath.isValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            lastError = AppError(title: "Invalid Coordinate",
                                 message: "Latitude must be between -90 and 90, longitude between -180 and 180.")
            return
        }
        route.appendWaypoint(name: name, coordinate: coordinate)
        persist(context)
    }

    func move(in route: TestRoute, from offsets: IndexSet, to destination: Int, context: ModelContext) {
        var ordered = route.orderedWaypoints
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, waypoint) in ordered.enumerated() { waypoint.order = index }
        persist(context)
    }

    func delete(from route: TestRoute, at offsets: IndexSet, context: ModelContext) {
        let ordered = route.orderedWaypoints
        for index in offsets where ordered.indices.contains(index) {
            let waypoint = ordered[index]
            route.waypoints.removeAll { $0.persistentModelID == waypoint.persistentModelID }
            context.delete(waypoint)
        }
        route.normalizeOrder()
        persist(context)
    }

    func relocate(_ waypoint: RouteWaypoint, to coordinate: CLLocationCoordinate2D, context: ModelContext) {
        guard RouteMath.isValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            lastError = AppError(title: "Invalid Coordinate", message: "That point is outside the valid range.")
            return
        }
        waypoint.latitude = coordinate.latitude
        waypoint.longitude = coordinate.longitude
        persist(context)
    }

    func reverse(_ route: TestRoute, context: ModelContext) {
        route.reverse()
        persist(context)
    }

    func clearWaypoints(of route: TestRoute, context: ModelContext) {
        for waypoint in route.waypoints { context.delete(waypoint) }
        route.waypoints.removeAll()
        persist(context)
    }

    func dismissError() {
        lastError = nil
    }

    private func persist(_ context: ModelContext) {
        do {
            try PersistenceService(context: context).save()
        } catch {
            lastError = AppError(title: "Could Not Save", message: error.localizedDescription)
        }
    }
}
