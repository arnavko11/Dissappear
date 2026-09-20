import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: SimulationModel

    var body: some View {
        NavigationStack {
            List {
                Section("Locations") {
                    ForEach(model.library.locations) { location in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.name)
                            Text(String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Routes") {
                    ForEach(model.library.routes) { route in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name)
                            Text("\(route.waypoints.count) waypoints · \(route.speed, specifier: "%.1f") m/s\(route.loops ? " · loops" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Scenarios") {
                    ForEach(model.library.scenarios) { scenario in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scenario.name)
                            Text(model.describe(scenario))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .overlay {
                if model.library.scenarios.isEmpty {
                    ContentUnavailableView("No Scenarios",
                                           systemImage: "map",
                                           description: Text("Add locations and routes in the macOS companion, then refresh the build."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.librarySource)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
        }
    }
}
