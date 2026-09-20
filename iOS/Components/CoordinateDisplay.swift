import CoreLocation
import SwiftUI

struct CoordinateDisplay: View {
    let coordinate: CLLocationCoordinate2D?
    var title: String = "Current Location"
    var precision: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(coordinate.map { CoordinateParser.format($0, precision: precision) } ?? "No test location")
                .font(.callout.monospacedDigit())
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(coordinate.map {
            "Latitude \($0.latitude.formatted(.number.precision(.fractionLength(4)))), longitude \($0.longitude.formatted(.number.precision(.fractionLength(4))))"
        } ?? "No test location")
    }
}
