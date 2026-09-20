import SwiftUI

struct SettingsView: View {
    @Environment(SimulationEngine.self) private var engine
    @Environment(LocationAuthorizationService.self) private var authorization
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.mapStyle) private var mapStyleRaw = MapStyleOption.standard.rawValue
    @AppStorage(PreferenceKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @AppStorage(PreferenceKey.appearance) private var appearanceRaw = AppearanceOption.system.rawValue
    @AppStorage(PreferenceKey.updateFrequency) private var updateFrequency = 20.0
    @AppStorage(PreferenceKey.smoothMarker) private var smoothMarker = true

    var body: some View {
        Form {
            Section("General") {
                Picker("Default Map Style", selection: $mapStyleRaw) {
                    ForEach(MapStyleOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Picker("Default Simulation Speed", selection: defaultSpeedBinding) {
                    ForEach(SimulationSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                Picker("Distance Units", selection: $distanceUnitRaw) {
                    ForEach(DistanceUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppearanceOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LabeledContent("Update Frequency") {
                    Stepper(value: $updateFrequency, in: 5...60, step: 5) {
                        Text("\(Int(updateFrequency)) Hz").monospacedDigit()
                    }
                    .onChange(of: updateFrequency) { _, value in
                        engine.updateFrequency = value
                    }
                }
                Toggle("Animate Marker Movement", isOn: $smoothMarker)
            } header: {
                Text("Simulation")
            } footer: {
                Text("Simulated fixes are delivered inside this app only. System location for other apps is never modified.")
            }

            Section {
                LabeledContent("Location Access", value: authorizationDescription)
                if authorization.status == .notDetermined {
                    Button("Request Access") { authorization.requestAuthorization() }
                }
            } header: {
                Text("Real Location")
            } footer: {
                Text("Optional. Core Location access is only used to show your device's real position alongside simulated fixes.")
            }

            AboutSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var authorizationDescription: String {
        switch authorization.status {
        case .authorizedAlways, .authorizedWhenInUse: return "Granted"
        case .denied: return "Denied in Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    private var defaultSpeedBinding: Binding<SimulationSpeed> {
        Binding(get: { SimulationSpeed.nearest(to: defaultSpeed) },
                set: { speed in
                    defaultSpeed = speed.rawValue
                    engine.speedMultiplier = speed.rawValue
                })
    }
}
