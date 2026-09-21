import SwiftUI

/// Steers the device-wide spoofed location from the phone itself, with the Mac
/// holding the developer session somewhere else on the network.
struct RemoteControlView: View {
    @Environment(RemoteControlClient.self) private var client
    @Environment(MainViewModel.self) private var main
    @State private var discovery = RemoteDiscovery()

    var body: some View {
        @Bindable var client = client

        List {
            Section {
                if discovery.companions.isEmpty {
                    HStack(spacing: 8) {
                        if discovery.isBrowsing { ProgressView().controlSize(.small) }
                        Text(discovery.isBrowsing ? "Looking for companions…" : "Not searching")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discovery.companions) { companion in
                        Button {
                            client.discovered = companion
                            Task { await client.refresh() }
                        } label: {
                            HStack {
                                Label(companion.name, systemImage: "desktopcomputer")
                                Spacer()
                                if client.discovered == companion {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                if let failure = discovery.failure {
                    InlineMessage(text: failure, tint: .orange)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Companions announce themselves on the local network. Pick one, then enter its pairing code below.")
            }

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
                    TextField("ABCD2345", text: $client.pairingCode)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onChange(of: client.pairingCode) { _, value in
                            let normalised = String(value.uppercased()
                                .filter { $0.isLetter || $0.isNumber }
                                .prefix(8))
                            if normalised != value { client.pairingCode = normalised }
                        }
                }
                Button(client.isBusy ? "Connecting…" : "Connect") {
                    Task { await client.refresh() }
                }
                .disabled(!client.isConfigured || client.isBusy)
            } header: {
                Text("Companion")
            } footer: {
                Text("Shown in the macOS companion under Settings ▸ Remote Control. Nearby discovery works on the same network; away from home, use the address the companion shows for your mesh VPN.")
            }

            if let trouble = client.trouble {
                Section {
                    switch trouble {
                    case let .unreachable(message):
                        InlineMessage(text: "Cannot reach the companion. \(message)",
                                      systemImage: "wifi.exclamationmark", tint: .orange)
                        Text("The Mac may be asleep or off this network. Device-wide spoofing stops when the companion does.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case let .refused(message):
                        InlineMessage(text: message, systemImage: "exclamationmark.circle", tint: .orange)
                    }
                    Button("Try Again") { Task { await client.refresh() } }
                }
            }

            if let status = client.status, !status.sessionLost.isEmpty {
                Section {
                    InlineMessage(text: status.sessionLost,
                                  systemImage: "bolt.horizontal.circle", tint: .orange)
                    if client.lastSent != nil {
                        Button {
                            Task { await client.reapplyLastLocation() }
                        } label: {
                            Label("Re-apply Last Location", systemImage: "arrow.clockwise")
                        }
                        .disabled(client.isBusy)
                    }
                } header: {
                    Text("Session Lost")
                }
            }

            if let status = client.status {
                Section("Status") {
                    LabeledContent("Mac Sees", value: status.device.isEmpty ? "No device" : status.device)
                    LabeledContent("Spoofing", value: status.simulating ? "Yes" : "No")
                    if status.simulating {
                        LabeledContent("Coordinate",
                                       value: String(format: "%.5f, %.5f", status.latitude, status.longitude))
                        if !status.name.isEmpty {
                            LabeledContent("Place", value: status.name)
                        }
                    }
                    if !status.ready {
                        InlineMessage(text: "The companion cannot spoof right now. Check the iPhone's connection to the Mac, and that Developer Mode is on.",
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
            discovery.start()
            // Keep the picture current: a session can die while the phone is
            // in a pocket, and silence would read as everything being fine.
            while !Task.isCancelled {
                // Skip while a request is already out, so a slow round trip
                // does not queue more behind it.
                if client.isConfigured, !client.isBusy { await client.refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onDisappear { discovery.stop() }
    }
}
