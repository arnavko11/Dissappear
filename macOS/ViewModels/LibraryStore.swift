import Foundation

/// Persists the simulation library the companion manages and ships into builds.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var library: SimulationLibrary {
        didSet { save() }
    }

    private let url: URL

    /// Application Support, or the home directory if the system will not name
    /// it. Force-unwrapping that lookup crashed the app on launch for a
    /// failure it could simply work around.
    static var applicationSupport: URL { AppPaths.applicationSupport }

    init() {
        let support = Self.applicationSupport
            .appendingPathComponent("DissappearCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("SimulationLibrary.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SimulationLibrary.self, from: data) {
            library = decoded
        } else {
            library = .sample
        }
    }

    func addLocation(name: String, latitude: Double, longitude: Double, note: String) {
        library.locations.append(SimulatedLocation(name: name, note: note,
                                                   coordinate: .init(latitude: latitude, longitude: longitude)))
    }

    func removeLocations(_ ids: Set<UUID>) {
        library.locations.removeAll { ids.contains($0.id) }
        library.scenarios.removeAll { $0.locationID.map(ids.contains) ?? false }
    }

    func addRoute(name: String, speed: Double, loops: Bool, from locations: [SimulatedLocation]) {
        guard locations.count > 1 else { return }
        library.routes.append(SimulatedRoute(name: name,
                                             waypoints: locations.map(\.coordinate),
                                             speed: speed,
                                             loops: loops))
    }

    func removeRoutes(_ ids: Set<UUID>) {
        library.routes.removeAll { ids.contains($0.id) }
        library.scenarios.removeAll { $0.routeID.map(ids.contains) ?? false }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(library).write(to: url, options: .atomic)
    }
}
