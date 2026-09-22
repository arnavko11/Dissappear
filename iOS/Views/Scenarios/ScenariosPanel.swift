import SwiftData
import SwiftUI

struct ScenariosPanel: View {
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(\.modelContext) private var context
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @Query(sort: \TestScenario.createdAt, order: .reverse) private var scenarios: [TestScenario]
    @State private var editingScenario: TestScenario?

    var body: some View {
        List {
            ForEach(scenarios) { scenario in
                Button { editingScenario = scenario } label: {
                    ScenarioRow(scenario: scenario, formatting: formatting)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(scenario) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { run(scenario) } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .tint(.accentColor)
                }
                .contextMenu {
                    Button("Run") { run(scenario) }
                    Button("Edit") { editingScenario = scenario }
                    Button("Duplicate") { duplicate(scenario) }
                    Button("Delete", role: .destructive) { delete(scenario) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if scenarios.isEmpty {
                EmptyStateView(title: "No Scenarios",
                               message: "A scenario pairs a route with a speed so a test run is repeatable.",
                               systemImage: "list.bullet.rectangle",
                               actionTitle: "New Scenario", action: create)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: create) { Label("New Scenario", systemImage: "plus") }
            }
        }
        .sheet(item: $editingScenario) { scenario in
            NavigationStack {
                ScenarioEditorView(scenario: scenario)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }

    private func create() {
        let scenario = TestScenario(name: "Scenario \(scenarios.count + 1)")
        context.insert(scenario)
        save()
        editingScenario = scenario
    }

    private func duplicate(_ scenario: TestScenario) {
        context.insert(TestScenario(name: "\(scenario.name) Copy",
                                    notes: scenario.notes,
                                    speedMultiplier: scenario.speedMultiplier,
                                    route: scenario.route))
        save()
    }

    private func delete(_ scenario: TestScenario) {
        context.delete(scenario)
        save()
    }

    private func run(_ scenario: TestScenario) {
        guard let route = scenario.route, route.waypoints.count > 1 else {
            main.present(AppError(title: "Scenario Not Runnable",
                                  message: "Assign a route with at least two waypoints to this scenario."))
            return
        }
        if let reason = spoofing.unavailableReason {
            main.present(AppError(title: "No Companion Connected", message: reason))
            return
        }
        main.editingRoute = route
        main.frame(coordinates: route.coordinates)
        Task {
            await spoofing.startRoute(name: route.name,
                                      waypoints: route.coordinates.map { ($0.latitude, $0.longitude) },
                                      speed: route.baseSpeed * scenario.speedMultiplier,
                                      loops: route.loops)
        }
        simulation.run(scenario: scenario)
    }

    private func save() {
        do {
            try PersistenceService(context: context).save()
        } catch {
            main.present(AppError(title: "Could Not Save Scenario", message: error.localizedDescription))
        }
    }
}
