import MapKit
import SwiftUI

/// Map style and zoom affordances, kept as small square buttons in the corner.
struct MapOverlayControls: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @AppStorage(PreferenceKey.mapStyle) private var mapStyleRaw = MapStyleOption.standard.rawValue

    var body: some View {
        VStack(spacing: 8) {
            Menu {
                Picker("Map Style", selection: $mapStyleRaw) {
                    ForEach(MapStyleOption.allCases) { option in
                        Label(option.title, systemImage: option.symbolName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                controlIcon("map")
            }
            .accessibilityLabel("Map style")

            VStack(spacing: 0) {
                Button { zoom(by: 0.5) } label: { controlIcon("plus") }
                    .accessibilityLabel("Zoom in")
                Divider().frame(width: 28)
                Button { zoom(by: 2) } label: { controlIcon("minus") }
                    .accessibilityLabel("Zoom out")
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            if engine.fix != nil {
                Button(action: recenter) { controlIcon("scope") }
                    .accessibilityLabel("Centre on simulated location")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    private func zoom(by factor: Double) {
        let region = main.visibleRegion ?? .defaultTestRegion
        let span = MKCoordinateSpan(latitudeDelta: min(max(region.span.latitudeDelta * factor, 0.0005), 120),
                                    longitudeDelta: min(max(region.span.longitudeDelta * factor, 0.0005), 120))
        withAnimation(.easeInOut(duration: 0.25)) {
            main.camera = .region(MKCoordinateRegion(center: region.center, span: span))
        }
    }

    private func recenter() {
        guard let fix = engine.fix else { return }
        main.focus(on: fix.coordinate, span: main.visibleRegion?.span.latitudeDelta ?? 0.02)
    }
}
