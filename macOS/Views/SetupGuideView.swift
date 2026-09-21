import SwiftUI

/// The first thing a new user sees: everything that has to be true before an
/// iPhone can be made to report a location it is not at, in order, each with
/// the one button that fixes it.
struct SetupGuideView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                banner

                VStack(spacing: 12) {
                    ForEach(steps) { step in
                        SetupStepRow(step: step)
                    }
                }

                if model.isReadyToSpoof {
                    GuidanceCard(title: "Ready",
                                 message: "Open Locations, pick anywhere on Earth, and your iPhone will report being there. Routes walks a path at a speed you choose.",
                                 systemImage: "checkmark.seal")
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Setup")
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await model.refreshAll()
                        await model.refreshFirewallStatus()
                    }
                } label: { Label("Re-check", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
            }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This app spoofs your iPhone's location")
                .font(.title.weight(.semibold))
            Text("""
            It replaces the GPS position your iPhone reports — to every app on it, \
            not just this one — with a coordinate you pick. That is the whole point \
            of it. Nothing below is optional; it is what Apple's developer location \
            service needs before it will let a Mac do this.
            """)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassPanel(cornerRadius: 16)
    }

    private var steps: [SetupStep] {
        [
            SetupStep(
                title: "Install Xcode",
                detail: model.toolchain.hasDeviceCtl
                    ? model.toolchain.summary
                    : "Apple's developer tools are how a Mac talks to an iPhone at all. The Command Line Tools alone are not enough — devicectl ships inside Xcode itself.",
                isDone: model.toolchain.hasDeviceCtl,
                instructions: model.toolchain.hasDeviceCtl ? nil : """
                1. Install Xcode from the Mac App Store. It is free and large — budget an hour.
                2. Open Xcode once and accept the licence when it asks.
                3. In Xcode ▸ Settings ▸ Locations, set Command Line Tools to that Xcode.
                4. Come back here and press Re-check.
                """,
                action: model.toolchain.hasDeviceCtl
                    ? nil
                    : .init(title: "Open the App Store", run: { model.openXcodeInAppStore() })),

            SetupStep(
                title: "Install the spoofing tool",
                detail: model.locationTooling.tool == nil
                    ? "pymobiledevice3 is the open source client for Apple's developer location service. This app installs it into a private folder it owns — no password, nothing touched outside that folder."
                    : model.locationTooling.displayName,
                isDone: model.locationTooling.tool != nil,
                instructions: nil,
                action: model.locationTooling.tool != nil
                    ? nil
                    : .init(title: model.toolingInstallActivity ?? "Install Automatically",
                            isBusy: model.toolingInstallActivity != nil,
                            run: { Task { await model.installLocationTooling() } })),

            SetupStep(
                title: "Connect an iPhone",
                detail: model.selectedDevice.map { "\($0.name) · \($0.platform) \($0.osVersion)" }
                    ?? "Plug an iPhone in over USB, unlock it, and tap Trust when it asks about this Mac.",
                isDone: model.selectedDevice != nil,
                instructions: model.selectedDevice != nil ? nil : model.deviceHint?.action,
                action: .init(title: "Look Again", run: { Task { await model.refreshDevices() } })),

            SetupStep(
                title: "Turn on Developer Mode",
                detail: model.selectedDevice?.developerMode == .enabled
                    ? "Enabled on \(model.selectedDevice?.name ?? "this iPhone")."
                    : "iOS refuses developer services until you allow them on the phone itself.",
                isDone: model.selectedDevice?.developerMode == .enabled,
                instructions: model.selectedDevice?.developerMode == .enabled ? nil : """
                On the iPhone: Settings ▸ Privacy & Security ▸ Developer Mode, turn it on, \
                and restart the phone when it asks. The switch only appears after a Mac \
                running Xcode has connected to it once.
                """,
                action: nil),

            SetupStep(
                title: "Start the developer tunnel",
                detail: model.isDeveloperTunnelRunning
                    ? "Running, and it starts itself after a restart."
                    : "iOS 17 and later reach the location service over a tunnel that needs administrator rights. macOS asks for your password once, then it runs itself from then on.",
                isDone: model.isDeveloperTunnelRunning || model.locationTooling.usesAppleTooling,
                instructions: nil,
                action: model.locationTooling.tool == nil
                    ? nil
                    : model.isDeveloperTunnelRunning
                        ? .init(title: "Stop Tunnel", run: { Task { await model.stopDeveloperTunnel() } })
                        : .init(title: "Start Tunnel", run: { Task { await model.startDeveloperTunnel() } })),

            SetupStep(
                title: "Let the phone through the firewall",
                detail: model.firewallStatus.isBlocking
                    ? "macOS is dropping the phone's connections before they reach this app, and does not prompt. The server looks like it is listening and the phone never gets an answer."
                    : "Nothing is blocking incoming connections.",
                isDone: !model.firewallStatus.isBlocking,
                instructions: nil,
                action: model.firewallStatus.isBlocking
                    ? .init(title: "Allow", run: { Task { await model.allowIncomingConnections() } })
                    : nil),

            SetupStep(
                title: "Pair your iPhone app",
                detail: model.controlServerAddress.map { "Listening on \($0)" }
                    ?? "Remote control lets the phone in your pocket steer the spoofed location while the Mac stays home.",
                isDone: model.isControlServerRunning,
                instructions: model.controlServerCode.map {
                    "In the Dissappear app on your iPhone, open Remote and enter the pairing code \($0)."
                },
                action: model.isControlServerRunning
                    ? nil
                    : .init(title: "Turn On", run: { model.startControlServer() }))
        ]
    }
}

struct SetupStep: Identifiable {
    struct Action {
        var title: String
        var isBusy: Bool = false
        var run: () -> Void
    }

    var title: String
    var detail: String
    var isDone: Bool
    var instructions: String?
    var action: Action?

    var id: String { title }
}

private struct SetupStepRow: View {
    let step: SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(step.isDone ? Color.green : Color.secondary)
                .accessibilityLabel(step.isDone ? "Done" : "Not done")

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.headline)
                Text(step.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let instructions = step.instructions {
                    Text(instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let action = step.action {
                HStack(spacing: 6) {
                    if action.isBusy { ProgressView().controlSize(.small) }
                    Button(action.title, action: action.run)
                        .disabled(action.isBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 14)
        .opacity(step.isDone ? 0.72 : 1)
    }
}
