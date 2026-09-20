import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        Group {
            if let device = model.selectedDevice {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView {
                    Label("No iPhone Connected", systemImage: "cable.connector.slash")
                } description: {
                    Text(model.toolchain.hasDeviceCtl
                         ? "Connect an iPhone over USB, unlock it, and tap Trust when prompted."
                         : "Install Xcode and its command line developer tools to detect connected devices.")
                } actions: {
                    Button("Refresh") { Task { await model.refreshAll() } }
                        .buttonStyle(.borderedProminent)
                }
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
                                  value: device.connection.displayName,
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
                }
                .formStyle(.grouped)

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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
