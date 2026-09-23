import Foundation
import SwiftData

/// SwiftData helpers plus the one-time import of the library prepared by the
/// macOS companion and embedded in the build.
@MainActor
struct PersistenceService {
    let context: ModelContext

    func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    func seedIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: PreferenceKey.didSeedLibrary) else { return }

        guard let url = Bundle.main.url(forResource: SimulationLibrary.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(SimulationLibrary.self, from: data) else { return }

        for location in library.locations {
            context.insert(SavedLocation(name: location.name,
                                         address: location.note,
                                         latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude))
        }

        for route in library.routes where route.waypoints.count > 1 {
            let imported = TestRoute(name: route.name, baseSpeed: max(route.speed, 0.1), loops: route.loops)
            context.insert(imported)
            for (index, waypoint) in route.waypoints.enumerated() {
                let point = RouteWaypoint(name: "Waypoint \(index + 1)",
                                          latitude: waypoint.latitude,
                                          longitude: waypoint.longitude,
                                          order: index)
                point.route = imported
                imported.waypoints.append(point)
            }
        }

        // Marked only once the work is done: it used to be set first, so a
        // seed that failed left the library permanently empty with no retry.
        do {
            try save()
            defaults.set(true, forKey: PreferenceKey.didSeedLibrary)
        } catch {
            context.rollback()
        }
    }
}
