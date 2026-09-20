import CoreLocation
import Observation

/// Transport layer between the UI and the simulation engine.
@MainActor
@Observable
final class SimulationViewModel {
    let engine: SimulationEngine

    init(engine: SimulationEngine) {
        self.engine = engine
    }

    var speed: SimulationSpeed {
        get { SimulationSpeed.nearest(to: engine.speedMultiplier) }
        set { engine.speedMultiplier = newValue.rawValue }
    }

    var canStart: Bool { engine.route?.isRunnable ?? false }
    var isRunning: Bool { engine.phase == .running }
    var isPaused: Bool { engine.phase == .paused }

    func run(route: TestRoute) {
        guard engine.load(RouteSnapshot(route: route)) else { return }
        engine.start()
    }

    func run(scenario: TestScenario) {
        guard let route = scenario.route else { return }
        engine.speedMultiplier = scenario.speedMultiplier
        run(route: route)
    }

    func load(route: TestRoute) {
        engine.load(RouteSnapshot(route: route))
    }

    func toggle() {
        switch engine.phase {
        case .running: engine.pause()
        case .paused: engine.resume()
        case .idle, .finished: engine.start()
        }
    }

    func stop() { engine.stop() }
    func restart() { engine.restart() }

    /// Returns the test session to its default state: no route, no simulated fix.
    func resetSession() {
        engine.clear()
        engine.speedMultiplier = 1
    }
}
