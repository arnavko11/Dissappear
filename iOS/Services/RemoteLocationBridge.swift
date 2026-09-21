import CoreLocation
import Foundation

/// Forwards the moving fix a route produces to the companion, so a route walks
/// the real device rather than a dot inside this app.
///
/// The engine stays the clock — it knows where along the route we are at this
/// instant — but it is no longer the destination. Nothing here is the source
/// of truth about where the phone claims to be; the companion is.
@MainActor
final class RemoteLocationBridge {
    /// Spoofed positions are worth about one a second: a phone's own GPS
    /// reports at roughly that rate, and the engine's 20 Hz tick would put two
    /// orders of magnitude more traffic on the link for no visible gain.
    private static let interval: Duration = .seconds(1)

    private var lastSent: CLLocationCoordinate2D?

    /// Runs until cancelled, pushing the engine's fix while a route plays.
    func run(engine: SimulationEngine, spoofing: SpoofingCoordinator) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }

            guard engine.phase == .running,
                  spoofing.canSpoof,
                  let fix = engine.fix else { continue }

            // Skip a coordinate that has not meaningfully moved, so a paused
            // or stationary route does not hammer the companion.
            if let lastSent, Self.isNear(lastSent, fix.coordinate) { continue }
            lastSent = fix.coordinate

            await spoofing.push(latitude: fix.coordinate.latitude,
                                longitude: fix.coordinate.longitude,
                                name: engine.route?.name)
        }
    }

    /// Within about a metre, which is below what a spoofed fix can express.
    private static func isNear(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.00001 && abs(a.longitude - b.longitude) < 0.00001
    }
}
