import SwiftUI

struct ScenarioRow: View {
    let scenario: TestScenario
    let formatting: MeasurementFormatting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(scenario.name).lineLimit(1)
            HStack(spacing: 6) {
                Text(scenario.route?.name ?? "No route")
                Text("·")
                Text("\(scenario.waypointCount) waypoints")
                Text("·")
                Text(SimulationSpeed.nearest(to: scenario.speedMultiplier).title)
                if scenario.estimatedDuration > 0 {
                    Text("·")
                    Text(formatting.duration(scenario.estimatedDuration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
