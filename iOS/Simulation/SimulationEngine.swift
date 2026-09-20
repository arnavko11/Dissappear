import Foundation

/// Produces simulated fixes for the app's own testing surfaces.
/// It is intentionally self-contained: nothing here touches Core Location's
/// system providers or the fixes delivered to any other app.
@MainActor
final class SimulationEngine: ObservableObject {
    struct Fix: Equatable {
        var coordinate: SimulatedCoordinate
        var horizontalAccuracy: Double
        var course: Double
        var speed: Double
        var timestamp: Date
    }

    @Published private(set) var fix: Fix?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0

    private var task: Task<Void, Never>?

    func start(scenario: SimulationScenario, library: SimulationLibrary) {
        stop()
        switch scenario.kind {
        case .fixed:
            guard let location = library.location(with: scenario.locationID) else { return }
            isRunning = true
            progress = 1
            emit(coordinate: location.coordinate, accuracy: scenario.horizontalAccuracy, course: 0, speed: 0)
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(scenario.updateInterval))
                    guard let self, !Task.isCancelled else { return }
                    self.emit(coordinate: location.coordinate, accuracy: scenario.horizontalAccuracy, course: 0, speed: 0)
                }
            }
        case .route:
            guard let route = library.route(with: scenario.routeID), route.waypoints.count > 1 else { return }
            isRunning = true
            task = Task { [weak self] in
                await self?.replay(route: route, scenario: scenario)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func replay(route: SimulatedRoute, scenario: SimulationScenario) async {
        let legs = Array(zip(route.waypoints, route.waypoints.dropFirst()))
        let lengths = legs.map { GeoMath.distance($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return }

        repeat {
            var travelled: Double = 0
            for (index, leg) in legs.enumerated() {
                let length = lengths[index]
                guard length > 0 else { continue }
                let course = GeoMath.course(from: leg.0, to: leg.1)
                var covered: Double = 0
                while covered < length {
                    if Task.isCancelled { return }
                    let coordinate = GeoMath.interpolate(leg.0, leg.1, fraction: covered / length)
                    emit(coordinate: coordinate, accuracy: scenario.horizontalAccuracy, course: course, speed: route.speed)
                    progress = min(1, (travelled + covered) / total)
                    try? await Task.sleep(for: .seconds(scenario.updateInterval))
                    covered += route.speed * scenario.updateInterval
                }
                travelled += length
            }
            progress = 1
        } while route.loops && !Task.isCancelled

        isRunning = false
    }

    private func emit(coordinate: SimulatedCoordinate, accuracy: Double, course: Double, speed: Double) {
        fix = Fix(coordinate: coordinate,
                  horizontalAccuracy: accuracy,
                  course: course,
                  speed: speed,
                  timestamp: Date())
    }
}
