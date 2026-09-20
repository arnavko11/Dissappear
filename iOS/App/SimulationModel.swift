import Foundation

@MainActor
final class SimulationModel: ObservableObject {
    @Published private(set) var library: SimulationLibrary
    @Published var selectedScenarioID: UUID?
    @Published private(set) var librarySource: String

    let engine = SimulationEngine()
    let buildInfo = BuildInfo.current()

    init() {
        if let url = Bundle.main.url(forResource: SimulationLibrary.resourceName, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SimulationLibrary.self, from: data) {
            library = decoded
            librarySource = "Embedded in build"
        } else {
            library = .sample
            librarySource = "Built-in sample"
        }
        selectedScenarioID = library.scenarios.first?.id
    }

    var selectedScenario: SimulationScenario? {
        library.scenarios.first { $0.id == selectedScenarioID }
    }

    func start() {
        guard let scenario = selectedScenario else { return }
        engine.start(scenario: scenario, library: library)
    }

    func stop() {
        engine.stop()
    }

    func describe(_ scenario: SimulationScenario) -> String {
        switch scenario.kind {
        case .fixed:
            return library.location(with: scenario.locationID)?.name ?? "Missing location"
        case .route:
            guard let route = library.route(with: scenario.routeID) else { return "Missing route" }
            return "\(route.name) · \(route.waypoints.count) waypoints"
        }
    }
}
