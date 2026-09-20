import SwiftUI

struct SavedLocationRow: View {
    let location: SavedLocation
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: location.isFavorite ? "star.fill" : "mappin.circle")
                .foregroundStyle(location.isFavorite ? .yellow : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .lineLimit(1)
                Text(location.address.isEmpty ? CoordinateParser.format(location.coordinate) : location.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens location details")
    }
}

struct PlaceRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
