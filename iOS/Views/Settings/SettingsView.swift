import SwiftUI

struct SettingsView: View {
    @Environment(SimulationEngine.self) private var engine
    @Environment(LocationAuthorizationService.self) private var authorization
    @Environment(PairingRecordStore.self) private var pairingRecords
    @Environment(SpoofingCoordinator.self) private var spoofing
    @State private var isImportingRecord = false
    @State private var importFailure: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.mapStyle) private var mapStyleRaw = MapStyleOption.standard.rawValue
    @AppStorage(PreferenceKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @AppStorage(PreferenceKey.appearance) private var appearanceRaw = AppearanceOption.system.rawValue
    @AppStorage(PreferenceKey.updateFrequency) private var updateFrequency = 20.0
    @AppStorage(PreferenceKey.smoothMarker) private var smoothMarker = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Spoofing Through") {
                    Text(routeDescription).foregroundStyle(.secondary)
                }

                if pairingRecords.hasRecord {
                    LabeledContent("Loopback Address") {
                        TextField("10.7.0.1", text: loopbackBinding)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button("Remove Pairing Record", role: .destructive) {
                        pairingRecords.removeRecord()
                    }
                } else {
                    Button("Import Pairing Record…") { isImportingRecord = true }
                }

                if let failure = spoofing.lastOnDeviceFailure {
                    InlineMessage(text: failure, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            } header: {
                Text("On This iPhone")
            } footer: {
                Text("With a pairing record imported, this phone drives its own developer services and no Mac has to be nearby — which is what makes spoofing work away from home. Export the record from the Mac companion under Devices. It also needs a loopback VPN running (StosVPN or LocalDevVPN), because iOS will not let an app reach its own device services directly. Keep the record private: anything holding it can reach this device's developer services.")
            }

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
                Text("Locations are applied by the Mac companion, so every app on this phone sees them. Without a paired companion nothing here can change your location, and the controls stay switched off.")
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

            RealLocationSection()

            AboutSection()
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $isImportingRecord,
                      allowedContentTypes: [.propertyList, .xml, .data]) { result in
            guard case let .success(url) = result else { return }
            do {
                try pairingRecords.importRecord(from: url)
            } catch {
                importFailure = "That file could not be read as a pairing record."
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importFailure != nil },
            set: { if !$0 { importFailure = nil } })) {
            Button("OK", role: .cancel) { importFailure = nil }
        } message: {
            Text(importFailure ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var routeDescription: String {
        switch spoofing.route {
        case .onDevice: return "This iPhone"
        case .companion: return "The Mac companion"
        case .unavailable: return "Nothing yet"
        }
    }

    private var loopbackBinding: Binding<String> {
        Binding(get: { spoofing.loopbackAddress },
                set: { spoofing.loopbackAddress = $0 })
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
