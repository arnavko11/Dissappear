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
                    LabeledContent("Loopback VPN") {
                        Text(spoofing.isLoopbackReachable ? "Connected" : "Not reachable")
                            .foregroundStyle(spoofing.isLoopbackReachable ? .secondary : Color.orange)
                    }
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
                Text("""
                Two things are needed, and this app ships neither — they are                 separate on purpose.

                1. A pairing record, exported from the Mac companion under                 Devices. It is the trust iOS established with that Mac, and                 cannot be forged. Keep it private: anything holding it can                 reach this device's developer services.

                2. A loopback VPN — StosVPN or LocalDevVPN, installed from                 the App Store or sideloaded, and switched on. This app will                 never ask you to add a VPN configuration, because the VPN is                 not part of it. iOS forbids an app from reaching its own                 device's services directly, so one of those apps has to                 publish a local address that routes back here.
                """)
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
        .task {
            // The VPN is another app, and can be switched off at any time.
            while !Task.isCancelled {
                await spoofing.refreshLoopback()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .fileImporter(isPresented: $isImportingRecord,
                      allowedContentTypes: [.propertyList, .xml, .data]) { result in
            guard case let .success(url) = result else { return }
            do {
                try pairingRecords.importRecord(from: url)
            } catch {
                // The store says exactly what is wrong with the file; replacing
                // that with a generic line would throw the answer away.
                importFailure = error.localizedDescription
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
