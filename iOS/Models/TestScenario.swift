import Foundation
import SwiftData

@Model
final class TestScenario {
    var name: String
    var notes: String
    var speedMultiplier: Double
    var createdAt: Date

    @Relationship(deleteRule: .nullify)
    var route: TestRoute?

    init(name: String,
         notes: String = "",
         speedMultiplier: Double = 1,
         route: TestRoute? = nil,
         createdAt: Date = .now) {
        self.name = name
        self.notes = notes
        self.speedMultiplier = speedMultiplier
        self.route = route
        self.createdAt = createdAt
    }

    /// Estimated run time with the scenario's own speed multiplier applied.
    var estimatedDuration: TimeInterval {
        guard let route, speedMultiplier > 0 else { return 0 }
        return route.estimatedDuration / speedMultiplier
    }

    var waypointCount: Int { route?.waypoints.count ?? 0 }
}
