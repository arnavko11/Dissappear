import SwiftUI

/// Persistent transport bar: current coordinate on the left, controls on the right.
struct SimulationBar: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SimulationViewModel.self) private var simulation
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue

    var body: some View {
        VStack(spacing: 8) {
            if engine.route != nil {
                ProgressView(value: engine.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Simulation progress")
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
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            CoordinateDisplay(coordinate: engine.fix?.coordinate)
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

        HStack(spacing: 10) {
            Button {
                simulation.toggle()
            } label: {
                Image(systemName: engine.phase == .running ? "pause.fill" : "play.fill")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!simulation.canStart)
            .accessibilityLabel(engine.phase == .running ? "Pause simulation" : "Start simulation")

            Button {
                simulation.restart()
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(!simulation.canStart)
            .accessibilityLabel("Restart simulation")

            Button {
                simulation.stop()
            } label: {
                Image(systemName: "stop.fill").frame(width: 26, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(!engine.isActive)
            .accessibilityLabel("Stop simulation")

            SpeedControl(speed: $simulation.speed)
        }
        .animation(.easeInOut(duration: 0.15), value: engine.phase)
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }
}
