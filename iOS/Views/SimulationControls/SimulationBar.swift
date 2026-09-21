import CoreLocation
import SwiftUI

/// Persistent transport bar: the spoofed coordinate on the left, controls on
/// the right.
struct SimulationBar: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(RemoteControlClient.self) private var client
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue

    var body: some View {
        VStack(spacing: 8) {
            if engine.route != nil {
                ProgressView(value: engine.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Route progress")
                    .accessibilityValue("\(Int(engine.progress * 100)) percent")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summary
                    Spacer(minLength: 12)
                    controls(simulation: simulation)
                }
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    controls(simulation: simulation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            CoordinateDisplay(coordinate: spoofedCoordinate)
            if let route = engine.route {
                Text("\(route.name) · \(formatting.distance(engine.remainingDistance)) left · \(formatting.duration(engine.estimatedTimeRemaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func controls(simulation: SimulationViewModel) -> some View {
        @Bindable var simulation = simulation

        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    simulation.toggle()
                } label: {
                    Image(systemName: engine.phase == .running ? "pause.fill" : "play.fill")
                        .frame(width: 26, height: 22)
                }
                .glassButton(prominent: true)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!simulation.canStart || !spoofing.canSpoof)
                .accessibilityLabel(engine.phase == .running ? "Pause" : "Start spoofing")

                Button {
                    simulation.restart()
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 22)
                }
                .glassButton()
                .disabled(!simulation.canStart || !spoofing.canSpoof)
                .accessibilityLabel("Restart")

                Button {
                    simulation.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 26, height: 22)
                }
                .glassButton()
                .disabled(!engine.isActive)
                .accessibilityLabel("Stop spoofing")

                SpeedControl(speed: $simulation.speed)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: engine.phase)
    }

    /// What the phone is reporting: the route's current point while one is
    /// playing, otherwise whatever the companion says is set on the device.
    private var spoofedCoordinate: CLLocationCoordinate2D? {
        if let fix = engine.fix { return fix.coordinate }
        guard let status = client.status, status.simulating else { return nil }
        return CLLocationCoordinate2D(latitude: status.latitude, longitude: status.longitude)
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }
}
