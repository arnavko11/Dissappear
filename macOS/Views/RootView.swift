import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case devices = "Devices"
    case locations = "Locations"
    case routes = "Routes"
    case scenarios = "Scenarios"
    case build = "Build"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .devices: return "iphone.gen3"
        case .locations: return "mappin.and.ellipse"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .scenarios: return "list.bullet.rectangle"
        case .build: return "hammer"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var selection: SidebarSection? = .devices

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Workspace") {
                    ForEach([SidebarSection.devices, .locations, .routes, .scenarios]) { section in
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
            switch selection ?? .devices {
            case .devices: DevicesView()
            case .locations: LocationsView()
            case .routes: RoutesView()
            case .scenarios: ScenariosView()
            case .build: BuildView()
            case .settings: SettingsView()
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title),
                  message: Text("\(error.details)\n\n\(error.recommendedAction)"),
                  dismissButton: .default(Text("OK")))
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
