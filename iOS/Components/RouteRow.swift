import SwiftUI

struct RouteRow: View {
    let route: TestRoute
    let formatting: MeasurementFormatting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.name).lineLimit(1)
            HStack(spacing: 6) {
                Label("\(route.waypoints.count)", systemImage: "mappin")
                Text("·")
                Text(formatting.distance(route.totalDistance))
                Text("·")
                Text(formatting.duration(route.estimatedDuration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(route.name)
        .accessibilityValue("\(route.waypoints.count) waypoints, \(formatting.distance(route.totalDistance)), about \(formatting.duration(route.estimatedDuration))")
    }
}
