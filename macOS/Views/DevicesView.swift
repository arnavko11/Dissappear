import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        Group {
            if let device = model.selectedDevice {
                DeviceDetailView(device: device)
            } else {
                NoDeviceView()
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.devices.count > 1 {
                    Picker("Device", selection: $model.selectedDeviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
        }
    }
}

struct DeviceDetailView: View {
    @EnvironmentObject private var model: CompanionModel
    let device: Device

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Form {
                    Section("Device") {
                        StatusRow(label: "Name", value: device.name)
                        StatusRow(label: "Model", value: device.displayModel)
                        StatusRow(label: "Identifier", value: device.productType)
                        StatusRow(label: "System", value: "\(device.platform) \(device.osVersion)")
                        StatusRow(label: "Connection",
                                  value: connectionDescription,
                                  state: device.connection == .connected ? .good : .warning)
                        StatusRow(label: "Developer Mode",
                                  value: device.developerMode.displayName,
                                  state: developerModeState)
                    }

                    Section("Development Build") {
                        StatusRow(label: "Installed",
                                  value: model.isAppInstalled ? "Installed" : "Not installed",
                                  state: model.isAppInstalled ? .good : .inactive)
                        if let app = model.installedApp {
                            StatusRow(label: "Version", value: app.version)
                            StatusRow(label: "Bundle ID", value: app.bundleIdentifier)
                        }
                        StatusRow(label: "Signing",
                                  value: model.provisioning.displayName,
                                  state: signingDotState)
                        if let profile = model.provisioning.profile {
                            StatusRow(label: "Profile", value: profile.name)
                            StatusRow(label: "Expiration",
                                      value: profile.expirationDate.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let days = model.signingState.daysRemaining {
                            StatusRow(label: "Days Remaining",
                                      value: "\(days)",
                                      state: days <= 2 ? .warning : .good)
                        }
                        if model.signingState.needsRefresh {
                            Label("A new development build is needed. Use Refresh Build to rebuild, sign and reinstall.",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        StatusRow(label: "Spoofing Tool",
                                  value: model.locationTooling.displayName,
                                  state: model.locationTooling.tool == nil ? .bad : .good)
                        StatusRow(label: "Reported Location",
                                  value: deviceLocationValue,
                                  state: model.deviceLocation == nil ? .inactive
                                       : (model.isDeviceDetached ? .warning : .good))
                        StatusRow(label: "Connection",
                                  value: model.deviceLink?.label ?? "Not established yet",
                                  state: model.deviceLink == nil ? .inactive : .good)

                        if model.locationTooling.tool == nil {
                            HStack(spacing: 10) {
                                Button("Install pymobiledevice3") {
                                    Task { await model.installLocationTooling() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.toolingInstallActivity != nil)

                                if let activity = model.toolingInstallActivity {
                                    ProgressView().controlSize(.small)
                                    Text(activity).foregroundStyle(.secondary)
                                }
                            }
                            Text("One click. It installs into a private folder this app owns, asks for no password, and touches nothing else on this Mac.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                Button("Prepare Device") {
                                    Task { await model.prepareDeviceForLocation() }
                                }
                                .disabled(model.isBusy)

                                if model.isDeveloperTunnelRunning {
                                    Button("Stop Tunnel") {
                                        Task { await model.stopDeveloperTunnel() }
                                    }
                                    .disabled(model.isBusy)
                                }

                                if model.deviceLocation != nil {
                                    Button(model.isDeviceDetached ? "Retry Stop Spoofing" : "Stop Spoofing",
                                           role: .destructive) {
                                        Task { await model.clearDeviceLocation() }
                                    }
                                    .disabled(model.isBusy)
                                }
                            }
                        }
                    } header: {
                        Text("Location Spoofing")
                    } footer: {
                        Text("Replaces the location this iPhone reports to every app on it — Maps, Find My, anything. It runs through Apple's own developer location service, so Developer Mode has to be on and the device has to trust this Mac. Pick where to appear in Locations, or a path to walk in Routes. Stop Spoofing puts real GPS back. Unplugging does not: the coordinate stays in force until it is cleared or the phone restarts. To keep control of it without the cable, turn on Wi-Fi sync for this phone in Finder — the companion will then reach it over the network.")
                    }

                }
                .formStyle(.grouped)

                if model.isDeviceDetached {
                    GuidanceCard(title: "The Spoofed Location Is Still Set",
                                 message: CompanionModel.detachedExplanation,
                                 systemImage: "cable.connector.slash")
                }
                if device.developerMode == .disabled || device.developerMode == .restricted {
                    GuidanceCard(title: "Enable Developer Mode",
                                 message: "On \(device.name), open Settings ▸ Privacy & Security ▸ Developer Mode, turn it on and restart the device when prompted.",
                                 systemImage: "hammer.circle")
                }
                if device.connection == .pairingNeeded {
                    GuidanceCard(title: "Trust This Computer",
                                 message: "Unlock \(device.name) and tap Trust when iOS asks whether to trust this Mac.",
                                 systemImage: "lock.shield")
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.title2.weight(.semibold))
                Text("\(device.displayModel) · \(device.platform) \(device.osVersion)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refreshAll() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }

            Button {
                Task { await model.reinstall() }
            } label: { Label("Reinstall", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)

            Button {
                Task { await model.launchInstalledApp() }
            } label: { Label("Open App", systemImage: "play.fill") }
                .disabled(!model.isAppInstalled)

            Button(role: .destructive) {
                Task { await model.removeInstalledApp() }
            } label: { Label("Remove", systemImage: "trash") }
                .disabled(!model.isAppInstalled)
        }
        .disabled(model.isBusy)
    }

    private var deviceLocationValue: String {
        guard let coordinate = model.deviceLocation else { return "Real GPS" }
        let name = model.deviceLocationName.map { "\($0) · " } ?? ""
        let coordinates = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        return name + coordinates + (model.isDeviceDetached ? " · phone disconnected" : "")
    }

    private var connectionDescription: String {
        let transport = device.transport.isEmpty ? "" : " · \(device.transport)"
        return device.connection.displayName + transport
    }

    private var developerModeState: StatusDot.State {
        switch device.developerMode {
        case .enabled: return .good
        case .disabled, .restricted: return .bad
        case .unknown: return .inactive
        }
    }

    private var signingDotState: StatusDot.State {
        switch model.provisioning {
        case .valid: return .good
        case .expiringSoon, .deviceNotRegistered: return .warning
        case .expired, .noProfile: return .bad
        case .unknown: return .inactive
        }
    }
}

struct GuidanceCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 14)
    }
}


/// Empty state that explains why no device was found and what to do next.
private struct NoDeviceView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label(hint?.title ?? "No iPhone Connected", systemImage: "cable.connector.slash")
                } description: {
                    Text(hint?.message ?? "Connect an iPhone over USB, unlock it, and tap Trust when prompted.")
                } actions: {
                    Button("Refresh") { Task { await model.refreshAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }

                if let action = hint?.action {
                    GuidanceCard(title: "What to do", message: action, systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: 520)
                }

                if let diagnostics = model.diagnostics {
                    TechnicalDetails(text: """
                    $ \(diagnostics.command)
                    exit code: \(diagnostics.exitCode)

                    \(diagnostics.output)

                    Developer directory: \(model.toolchain.developerDirectory ?? "not set")
                    xcodebuild: \(model.toolchain.hasXcodebuild ? model.toolchain.summary : "not available")
                    devicectl: \(model.toolchain.hasDeviceCtl ? "available" : "not available")
                    USB Apple devices: \(diagnostics.usbDeviceNames.isEmpty ? "none" : diagnostics.usbDeviceNames.joined(separator: ", "))
                    """)
                    .frame(maxWidth: 520)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var hint: (title: String, message: String, action: String?)? {
        model.deviceHint
    }
}
