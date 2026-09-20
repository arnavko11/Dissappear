import MapKit
import SwiftUI

struct SimulationView: View {
    @EnvironmentObject private var model: SimulationModel

    var body: some View {
        NavigationStack {
            SimulationContent(model: model, engine: model.engine)
                .navigationTitle("Simulation")
        }
    }
}

private struct SimulationContent: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var engine: SimulationEngine
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        List {
            Section("Scenario") {
                Picker("Scenario", selection: $model.selectedScenarioID) {
                    ForEach(model.library.scenarios) { scenario in
                        Text(scenario.name).tag(Optional(scenario.id))
                    }
                }
                .pickerStyle(.navigationLink)

                if let scenario = model.selectedScenario {
                    LabeledContent("Target", value: model.describe(scenario))
                    LabeledContent("Accuracy", value: "\(Int(scenario.horizontalAccuracy)) m")
                    LabeledContent("Interval", value: String(format: "%.1f s", scenario.updateInterval))
                }
            }

            Section("Simulated Fix") {
                if let fix = engine.fix {
                    LabeledContent("Latitude", value: String(format: "%.6f", fix.coordinate.latitude))
                    LabeledContent("Longitude", value: String(format: "%.6f", fix.coordinate.longitude))
                    LabeledContent("Course", value: String(format: "%.0f°", fix.course))
                    LabeledContent("Speed", value: String(format: "%.1f m/s", fix.speed))
                    LabeledContent("Updated", value: fix.timestamp.formatted(date: .omitted, time: .standard))
                } else {
                    Text("No simulated fix yet").foregroundStyle(.secondary)
                }
                if engine.isRunning {
                    ProgressView(value: engine.progress)
                }
            }

            Section {
                Map(position: $camera) {
                    if let fix = engine.fix {
                        Marker("Simulated", systemImage: "location.fill",
                               coordinate: CLLocationCoordinate2D(latitude: fix.coordinate.latitude,
                                                                  longitude: fix.coordinate.longitude))
                    }
                }
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if engine.isRunning {
                    Button("Stop Simulation", role: .destructive) { model.stop() }
                } else {
                    Button("Start Simulation") { model.start() }
                        .disabled(model.selectedScenario == nil)
                }
            } footer: {
                Text("Simulated fixes stay inside this test app. System location for other apps is unchanged.")
            }
        }
        .onChange(of: engine.fix) { _, fix in
            guard let fix else { return }
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }
}
