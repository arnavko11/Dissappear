import SwiftData
import SwiftUI

struct RoutesPanel: View {
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(\.modelContext) private var context
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @Query(sort: \TestRoute.createdAt, order: .reverse) private var routes: [TestRoute]

    var body: some View {
        List {
            Section {
                ForEach(routes) { route in
                    NavigationLink {
                        RouteEditorView(route: route)
                    } label: {
                        RouteRow(route: route, formatting: formatting)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(route) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Run Simulation") { run(route) }
                        Button("Show on Map") { show(route) }
                        Button("Duplicate") { duplicate(route) }
                        Button("Delete", role: .destructive) { delete(route) }
                    }
                }
            } footer: {
                if !routes.isEmpty {
                    Text("Open a route to add, reorder, or move waypoints.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if routes.isEmpty {
                EmptyStateView(title: "No Routes",
                               message: "Create a route, then add waypoints from the map or your saved locations.",
                               systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                               actionTitle: "New Route", action: createRoute)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createRoute) {
                    Label("New Route", systemImage: "plus")
                }
            }
        }
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }

    private func createRoute() {
        let route = TestRoute(name: "Route \(routes.count + 1)")
        context.insert(route)
        save()
        main.editingRoute = route
    }

    private func duplicate(_ route: TestRoute) {
        let copy = TestRoute(name: "\(route.name) Copy", baseSpeed: route.baseSpeed, loops: route.loops)
        context.insert(copy)
        for waypoint in route.orderedWaypoints {
            copy.appendWaypoint(name: waypoint.name, coordinate: waypoint.coordinate)
        }
        save()
    }

    private func delete(_ route: TestRoute) {
        if main.editingRoute?.persistentModelID == route.persistentModelID {
            main.editingRoute = nil
        }
        context.delete(route)
        save()
    }

    private func show(_ route: TestRoute) {
        main.editingRoute = route
        main.frame(coordinates: route.coordinates)
    }

    private func run(_ route: TestRoute) {
        guard route.waypoints.count > 1 else {
            main.present(AppError(title: "Route Needs More Waypoints",
                                  message: "Add at least two waypoints before walking it."))
            return
        }
        if let reason = spoofing.unavailableReason {
            main.present(AppError(title: "No Companion Connected", message: reason))
            return
        }
        show(route)
        // The engine still runs, as the clock and the dot on the map, but the
        // companion is handed the whole track rather than a point a second:
        // each point would open a fresh developer session, which takes longer
        // than the interval between them.
        Task {
            await spoofing.startRoute(name: route.name,
                                      waypoints: route.coordinates.map { ($0.latitude, $0.longitude) },
                                      speed: route.baseSpeed,
                                      loops: route.loops)
        }
        simulation.run(route: route)
    }

    private func save() {
        do {
            try PersistenceService(context: context).save()
        } catch {
            main.present(AppError(title: "Could Not Save Route", message: error.localizedDescription))
        }
    }
}
