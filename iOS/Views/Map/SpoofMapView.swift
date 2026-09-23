import MapKit
import SwiftUI

struct SpoofMapView: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.mapStyle) private var mapStyleRaw = MapStyleOption.standard.rawValue
    @AppStorage(PreferenceKey.smoothMarker) private var smoothMarker = true

    let onMapTap: (CLLocationCoordinate2D) -> Void
    let onWaypointTap: (RouteWaypoint) -> Void

    var body: some View {
        @Bindable var main = main

        MapReader { proxy in
            Map(position: $main.camera) {
                routeOverlay
                waypointMarkers
                previewMarker
                simulatedMarker
            }
            .mapStyle(style.mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                onMapTap(coordinate)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                main.visibleRegion = context.region
            }
        }
        .accessibilityLabel("Map")
        .accessibilityValue(engine.fix.map { "Spoofed location \(CoordinateParser.format($0.coordinate))" } ?? "No spoofed location")
    }

    private var style: MapStyleOption {
        MapStyleOption(rawValue: mapStyleRaw) ?? .standard
    }

    @MapContentBuilder
    private var routeOverlay: some MapContent {
        if let route = main.editingRoute, route.waypoints.count > 1 {
            MapPolyline(coordinates: route.coordinates)
                .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }

    @MapContentBuilder
    private var waypointMarkers: some MapContent {
        if let route = main.editingRoute {
            ForEach(Array(route.orderedWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                Annotation(waypoint.name, coordinate: waypoint.coordinate) {
                    WaypointBadge(index: index + 1, isTarget: isMoveTarget(waypoint))
                        .onTapGesture { onWaypointTap(waypoint) }
                }
                .annotationTitles(.hidden)
            }
        }
    }

    @MapContentBuilder
    private var previewMarker: some MapContent {
        if let place = main.previewPlace {
            Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                .tint(.red)
        }
    }

    @MapContentBuilder
    private var simulatedMarker: some MapContent {
        if engine.fix == nil, let spoofed = spoofing.displayed {
            Annotation("Spoofed location",
                       coordinate: CLLocationCoordinate2D(latitude: spoofed.latitude, longitude: spoofed.longitude)) {
                SimulatedFixMarker(course: 0, isMoving: false)
            }
            .annotationTitles(.hidden)
        }
        if let fix = engine.fix {
            Annotation("Spoofed location", coordinate: fix.coordinate) {
                SimulatedFixMarker(course: fix.course, isMoving: engine.phase == .running)
                    .animation(animation, value: fix)
            }
            .annotationTitles(.hidden)
        }
    }

    private var animation: Animation? {
        guard smoothMarker, !reduceMotion else { return nil }
        return .linear(duration: 1 / max(1, engine.updateFrequency))
    }

    private func isMoveTarget(_ waypoint: RouteWaypoint) -> Bool {
        if case let .moveWaypoint(identifier) = main.tapMode {
            return identifier == waypoint.persistentModelID
        }
        return false
    }
}

private struct WaypointBadge: View {
    let index: Int
    let isTarget: Bool

    var body: some View {
        Text("\(index)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(6)
            .background(isTarget ? Color.orange : Color.accentColor, in: Circle())
            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            .accessibilityLabel("Waypoint \(index)")
            .accessibilityHint(isTarget ? "Selected. Tap the map to move it." : "Tap to edit")
    }
}

private struct SimulatedFixMarker: View {
    let course: CLLocationDirection
    let isMoving: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.22))
                .frame(width: 34, height: 34)
            Image(systemName: isMoving ? "location.north.fill" : "location.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.tint, in: Circle())
                .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                .rotationEffect(isMoving ? .degrees(course) : .zero)
        }
        .accessibilityLabel("Spoofed location")
    }
}
