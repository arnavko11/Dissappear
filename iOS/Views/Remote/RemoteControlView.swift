import SwiftUI

/// Steers the simulated location on the device from the phone itself, with the
/// Mac holding the developer session somewhere else on the network.
struct RemoteControlView: View {
    @Environment(RemoteControlClient.self) private var client
    @Environment(MainViewModel.self) private var main

    var body: some View {
        @Bindable var client = client

        List {
            Section {
                LabeledContent("Address") {
                    TextField("192.168.1.10", text: $client.host)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Port") {
                    TextField("8787", text: $client.port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                LabeledContent("Pairing Code") {
                    TextField("000000", text: $client.pairingCode)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Button("Connect") { Task { await client.refresh() } }
                    .disabled(!client.isConfigured || client.isBusy)
            } header: {
                Text("Companion")
            } footer: {
                Text("Shown in the macOS companion under Settings ▸ Remote Control. Both devices must be on the same network.")
            }

            if let error = client.lastError {
                Section {
                    InlineMessage(text: error, tint: .orange)
                }
            }

            if let status = client.status {
                Section("Status") {
                    LabeledContent("Mac Sees", value: status.device.isEmpty ? "No device" : status.device)
                    LabeledContent("Simulating", value: status.simulating ? "Yes" : "No")
                    if status.simulating {
                        LabeledContent("Coordinate",
                                       value: String(format: "%.5f, %.5f", status.latitude, status.longitude))
                        if !status.name.isEmpty {
                            LabeledContent("Place", value: status.name)
                        }
                    }
                    if !status.ready {
                        InlineMessage(text: "The companion cannot simulate right now. Check the device connection on the Mac.",
                                      tint: .orange)
                    }
                }
            }

            Section("Send") {
                Button {
                    guard let centre = main.visibleRegion?.center else { return }
                    Task { await client.setLocation(latitude: centre.latitude,
                                                    longitude: centre.longitude,
                                                    name: "Map centre") }
                } label: {
                    Label("Use Map Centre", systemImage: "scope")
                }
                .disabled(!client.isConfigured || client.isBusy || main.visibleRegion == nil)

                Button(role: .destructive) {
                    Task { await client.clearLocation() }
                } label: {
                    Label("Restore Real Location", systemImage: "location.slash")
                }
                .disabled(!client.isConfigured || client.isBusy)
            }

            if !client.places.isEmpty {
                Section("Saved on the Mac") {
                    ForEach(client.places) { place in
                        Button {
                            Task { await client.setLocation(latitude: place.latitude,
                                                            longitude: place.longitude,
                                                            name: place.name) }
                        } label: {
                            PlaceRow(title: place.name,
                                     subtitle: String(format: "%.5f, %.5f", place.latitude, place.longitude))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if client.isBusy { ProgressView() }
        }
        .task {
            if client.isConfigured { await client.refresh() }
        }
    }
}
