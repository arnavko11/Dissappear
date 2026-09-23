import CoreLocation
import SwiftUI

/// The main control: where the phone is being told it is, one button to spoof
/// the spot under the crosshair, one to put the real location back. Route
/// controls appear only while a route is loaded.
struct SimulationBar: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(SpoofingCoordinator.self) private var spoofing
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary

            if engine.route != nil { routeControls }

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        guard let centre = main.visibleRegion?.center else { return }
                        Task { await spoofing.spoof(latitude: centre.latitude,
                                                    longitude: centre.longitude,
                                                    name: nil) }
                    } label: {
                        Label("Spoof Here", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .disabled(!spoofing.canSpoof || spoofing.isWorking || main.visibleRegion == nil)

                    Button {
                        // Stopping has to reach the device: halting the clock
                        // in here left the phone on the last spoofed point.
                        // Not gated on isWorking — it is the way out.
                        simulation.stop()
                        Task { await spoofing.clear() }
                    } label: {
                        Label("Real Location", systemImage: "location.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .disabled(!spoofing.canSpoof && !spoofing.isSpoofing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassPanel(cornerRadius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: displayedCoordinate == nil ? "location" : "location.fill")
                .foregroundStyle(displayedCoordinate == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if spoofing.isWorking { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard displayedCoordinate != nil else { return "Real location" }
        if let route = engine.route, engine.isActive { return route.name }
        return spoofing.displayed?.name ?? "Spoofed"
    }

    private var subtitle: String {
        if let coordinate = displayedCoordinate {
            var text = CoordinateParser.format(coordinate, precision: 5)
            if engine.route != nil, engine.isActive {
                text += " · \(formatting.distance(engine.remainingDistance)) left"
            }
            return text
        }
        return spoofing.unavailableReason ?? "Move the map, then Spoof Here — or tap the map to drop a pin."
    }

    private var routeControls: some View {
        VStack(spacing: 8) {
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Route progress")
            HStack(spacing: 10) {
                Button {
                    simulation.toggle()
                } label: {
                    Image(systemName: engine.phase == .running ? "pause.fill" : "play.fill")
                        .frame(width: 26, height: 22)
                }
                .glassButton(prominent: true)
                // The Mac replays a track in one go; it cannot be paused partway.
                .disabled(!simulation.canStart || !spoofing.canSpoof || spoofing.isCompanionPlayingRoute)
                .accessibilityLabel(engine.phase == .running ? "Pause route" : "Play route")

                Button {
                    simulation.restart()
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 26, height: 22)
                }
                .glassButton()
                .disabled(!simulation.canStart || !spoofing.canSpoof)
                .accessibilityLabel("Restart route")

                SpeedControl(speed: Binding(get: { simulation.speed },
                                            set: { simulation.speed = $0 }))
                Spacer(minLength: 0)
            }
        }
    }

    /// The route's point while one plays, otherwise what the device was told.
    private var displayedCoordinate: CLLocationCoordinate2D? {
        if let fix = engine.fix, engine.isActive { return fix.coordinate }
        guard let spoofed = spoofing.displayed else { return nil }
        return CLLocationCoordinate2D(latitude: spoofed.latitude, longitude: spoofed.longitude)
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }
}
