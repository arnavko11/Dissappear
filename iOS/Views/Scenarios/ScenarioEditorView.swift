import SwiftData
import SwiftUI

struct ScenarioEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @Query(sort: \TestRoute.name) private var routes: [TestRoute]

    @Bindable var scenario: TestScenario

    var body: some View {
        Form {
            Section("Scenario") {
                TextField("Name", text: $scenario.name)
                TextField("Notes", text: $scenario.notes, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("Route") {
                Picker("Route", selection: routeBinding) {
                    Text("None").tag(Optional<PersistentIdentifier>.none)
                    ForEach(routes) { route in
                        Text(route.name).tag(Optional(route.persistentModelID))
                    }
                }
                if routes.isEmpty {
                    InlineMessage(text: "Create a route first — a scenario runs a saved route.", tint: .orange)
                }
            }

            Section("Playback") {
                Picker("Speed", selection: speedBinding) {
                    ForEach(SimulationSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                LabeledContent("Waypoints", value: "\(scenario.waypointCount)")
                LabeledContent("Estimated Duration",
                               value: MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
                                   .duration(scenario.estimatedDuration))
            }
        }
        .navigationTitle("Edit Scenario")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? PersistenceService(context: context).save()
                    dismiss()
                }
            }
        }
    }

    private var routeBinding: Binding<PersistentIdentifier?> {
        Binding(get: { scenario.route?.persistentModelID },
                set: { identifier in
                    scenario.route = routes.first { $0.persistentModelID == identifier }
                })
    }

    private var speedBinding: Binding<SimulationSpeed> {
        Binding(get: { SimulationSpeed.nearest(to: scenario.speedMultiplier) },
                set: { scenario.speedMultiplier = $0.rawValue })
    }
}
