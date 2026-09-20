import SwiftUI

struct ScenariosView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var model: CompanionModel
    @State private var selection = Set<UUID>()
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            Table(store.library.scenarios, selection: $selection) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Kind") { Text($0.kind == .fixed ? "Fixed" : "Route") }
                TableColumn("Target") { scenario in
                    Text(target(for: scenario)).foregroundStyle(.secondary)
                }
                TableColumn("Accuracy") { Text("\(Int($0.horizontalAccuracy)) m") }
            }
            Divider()
            HStack {
                Label("Scenarios are embedded into the iOS build during Prepare.", systemImage: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Build") { Task { await model.refreshBuild() } }
                    .disabled(model.isBusy)
            }
            .padding(12)
        }
        .navigationTitle("Scenarios")
        .toolbar {
            ToolbarItemGroup {
                Button { isAdding = true } label: { Label("Add", systemImage: "plus") }
                Button(role: .destructive) {
                    store.removeScenarios(selection)
                    selection = []
                } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection.isEmpty)
            }
        }
        .sheet(isPresented: $isAdding) { AddScenarioSheet() }
    }

    private func target(for scenario: SimulationScenario) -> String {
        switch scenario.kind {
        case .fixed: return store.library.location(with: scenario.locationID)?.name ?? "—"
        case .route: return store.library.route(with: scenario.routeID)?.name ?? "—"
        }
    }
}

private struct AddScenarioSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: SimulationScenario.Kind = .fixed
    @State private var locationID: UUID?
    @State private var routeID: UUID?
    @State private var accuracy = 5.0
    @State private var interval = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "New Scenario", subtitle: "Bundled with the next development build.")
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("Fixed Location").tag(SimulationScenario.Kind.fixed)
                    Text("Route").tag(SimulationScenario.Kind.route)
                }
                .pickerStyle(.segmented)

                if kind == .fixed {
                    Picker("Location", selection: $locationID) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(store.library.locations) { Text($0.name).tag(Optional($0.id)) }
                    }
                } else {
                    Picker("Route", selection: $routeID) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(store.library.routes) { Text($0.name).tag(Optional($0.id)) }
                    }
                }

                LabeledContent("Accuracy") {
                    Stepper(value: $accuracy, in: 1...100, step: 1) {
                        Text("\(Int(accuracy)) m")
                    }
                }
                LabeledContent("Update Interval") {
                    Stepper(value: $interval, in: 0.25...10, step: 0.25) {
                        Text(String(format: "%.2f s", interval))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    store.addScenario(SimulationScenario(name: name.isEmpty ? "Untitled Scenario" : name,
                                                         kind: kind,
                                                         locationID: kind == .fixed ? locationID : nil,
                                                         routeID: kind == .route ? routeID : nil,
                                                         horizontalAccuracy: accuracy,
                                                         updateInterval: interval))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(kind == .fixed ? locationID == nil : routeID == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
