import CoreLocation
import Foundation
import Observation

/// Interpolates a simulated coordinate along a route snapshot.
///
/// The engine is deliberately self-contained: it publishes fixes to this app's
/// own testing surfaces only. It does not hook into Core Location's system
/// providers and does not change the location delivered to any other app.
@MainActor
@Observable
final class SimulationEngine {
    private(set) var phase: SimulationPhase = .idle
    private(set) var fix: SimulatedFix?
    private(set) var route: RouteSnapshot?
    private(set) var travelled: CLLocationDistance = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: AppError?

    var speedMultiplier: Double = 1
    /// Simulated fixes emitted per second.
    var updateFrequency: Double = 20

    private var task: Task<Void, Never>?
    private var legLengths: [CLLocationDistance] = []

    var progress: Double {
        guard let route, route.totalDistance > 0 else { return 0 }
        return min(1, travelled / route.totalDistance)
    }

    var remainingDistance: CLLocationDistance {
        guard let route else { return 0 }
        return max(0, route.totalDistance - travelled)
    }

    var estimatedTimeRemaining: TimeInterval {
        guard let route, route.baseSpeed > 0, speedMultiplier > 0 else { return 0 }
        return remainingDistance / (route.baseSpeed * speedMultiplier)
    }

    var isActive: Bool { phase == .running || phase == .paused }

    // MARK: - Transport

    @discardableResult
    func load(_ snapshot: RouteSnapshot) -> Bool {
        guard snapshot.isRunnable else {
            lastError = AppError(title: "Route Not Runnable",
                                 message: "A route needs at least two waypoints and a speed above zero.")
            return false
        }
        stop()
        route = snapshot
        legLengths = zip(snapshot.coordinates, snapshot.coordinates.dropFirst()).map { start, end in
            CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        travelled = 0
        elapsed = 0
        lastError = nil
        emitFix(at: 0)
        return true
    }

    func start() {
        guard let route, route.isRunnable else {
            lastError = AppError(title: "Nothing to Simulate",
                                 message: "Select a route or scenario with at least two waypoints first.")
            return
        }
        guard phase != .running else { return }
        if phase == .finished {
            travelled = 0
            elapsed = 0
        }
        phase = .running
        lastError = nil
        run()
    }

    func pause() {
        guard phase == .running else { return }
        task?.cancel()
        task = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .running
        run()
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .idle
        travelled = 0
        elapsed = 0
        if route != nil { emitFix(at: 0) }
    }

    func restart() {
        guard route != nil else { return }
        stop()
        start()
    }

    /// Places the test session at a single coordinate with no route loaded.
    func setFixedLocation(_ coordinate: CLLocationCoordinate2D, course: CLLocationDirection = 0) {
        stop()
        route = nil
        legLengths = []
        fix = SimulatedFix(coordinate: coordinate, course: course, speed: 0, timestamp: .now)
    }

    func clear() {
        stop()
        route = nil
        legLengths = []
        fix = nil
    }

    // MARK: - Loop

    private func run() {
        task?.cancel()
        let interval = 1 / max(1, updateFrequency)
        task = Task { [weak self] in
            var lastTick = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let components = lastTick.duration(to: now).components
                let delta = Double(components.seconds) + Double(components.attoseconds) * 1e-18
                lastTick = now
                self.advance(by: delta)
                if self.phase != .running { return }
            }
        }
    }

    private func advance(by delta: TimeInterval) {
        guard let route, phase == .running else { return }
        elapsed += delta
        travelled += route.baseSpeed * speedMultiplier * delta

        if travelled >= route.totalDistance {
            if route.loops {
                travelled = travelled.truncatingRemainder(dividingBy: max(route.totalDistance, 0.001))
            } else {
                travelled = route.totalDistance
                emitFix(at: travelled)
                phase = .finished
                task?.cancel()
                task = nil
                return
            }
        }
        emitFix(at: travelled)
    }

    private func emitFix(at distance: CLLocationDistance) {
        guard let route, let position = position(at: distance) else { return }
        fix = SimulatedFix(coordinate: position.coordinate,
                           course: position.course,
                           speed: phase == .running ? route.baseSpeed * speedMultiplier : 0,
                           timestamp: .now)
    }

    private func position(at distance: CLLocationDistance) -> (coordinate: CLLocationCoordinate2D, course: CLLocationDirection)? {
        guard let route, let first = route.coordinates.first else { return nil }
        guard distance > 0 else {
            let next = route.coordinates.count > 1 ? route.coordinates[1] : first
            return (first, RouteMath.course(from: first, to: next))
        }

        var remaining = distance
        for (index, length) in legLengths.enumerated() {
            if remaining <= length || index == legLengths.count - 1 {
                let start = route.coordinates[index]
                let end = route.coordinates[index + 1]
                let fraction = length > 0 ? min(1, remaining / length) : 1
                return (RouteMath.interpolate(from: start, to: end, fraction: fraction),
                        RouteMath.course(from: start, to: end))
            }
            remaining -= length
        }

        let last = route.coordinates[route.coordinates.count - 1]
        let previous = route.coordinates[max(0, route.coordinates.count - 2)]
        return (last, RouteMath.course(from: previous, to: last))
    }
}
