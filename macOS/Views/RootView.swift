import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case setup = "Setup"
    case devices = "Devices"
    case locations = "Locations"
    case routes = "Routes"
    case build = "Build"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .setup: return "checklist"
        case .devices: return "iphone.gen3"
        case .locations: return "mappin.and.ellipse"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .build: return "hammer"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var selection: SidebarSection?

    /// Setup until it is no longer needed.
    private var defaultSection: SidebarSection {
        model.isReadyToSpoof ? .devices : .setup
    }

    /// Keeps the alert readable: the details are there, but a wall of tool
    /// output goes to the clipboard rather than into a dialog.
    private static func message(for failure: CompanionError) -> String {
        var text = "\(failure.details)\n\n\(failure.recommendedAction)"
        let technical = failure.technicalDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        if !technical.isEmpty {
            let excerpt = technical.split(separator: "\n").suffix(8).joined(separator: "\n")
            text += "\n\n\(excerpt)"
        }
        return text
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Spoofing") {
                    ForEach([SidebarSection.setup, .devices, .locations, .routes]) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                }
                Section("Development") {
                    ForEach([SidebarSection.build, .settings]) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { DeviceStatusFooter() }
        } detail: {
            switch selection ?? defaultSection {
            case .setup: SetupGuideView()
            case .devices: DevicesView()
            case .locations: LocationsView()
            case .routes: RoutesView()
            case .build: BuildView()
            case .settings: SettingsView()
            }
        }
        .task {
            // New users land on Setup; once spoofing works, on the device.
            if selection == nil { selection = defaultSection }
        }
        // The technical details used to be collected and then never shown,
        // which left failures like a tunnel that would not bind as a dead end.
        .alert(model.error?.title ?? "Error",
               isPresented: Binding(get: { model.error != nil },
                                    set: { if !$0 { model.error = nil } }),
               presenting: model.error) { failure in
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("""
                \(failure.title)

                \(failure.details)

                \(failure.recommendedAction)

                \(failure.technicalDetails)
                """, forType: .string)
                model.error = nil
            }
            Button("OK", role: .cancel) { model.error = nil }
        } message: { failure in
            Text(Self.message(for: failure))
        }
    }
}

private struct DeviceStatusFooter: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                StatusDot(state: dotState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedDevice?.name ?? "No device")
                        .font(.callout)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var dotState: StatusDot.State {
        guard let device = model.selectedDevice else { return .inactive }
        switch device.connection {
        case .connected: return .good
        case .pairingNeeded: return .warning
        case .unavailable: return .bad
        }
    }

    private var subtitle: String {
        guard let device = model.selectedDevice else {
            return model.toolchain.hasDeviceCtl ? "Connect over USB" : "Xcode required"
        }
        return "\(device.platform) \(device.osVersion) · \(device.connection.displayName)"
    }
}
