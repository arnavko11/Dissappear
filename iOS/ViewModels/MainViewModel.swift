import MapKit
import Observation
import SwiftData
import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case search = "Search"
    case saved = "Saved"
    case routes = "Routes"
    case scenarios = "Scenarios"
    case remote = "Remote"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .search: return "magnifyingglass"
        case .saved: return "mappin.and.ellipse"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .scenarios: return "list.bullet.rectangle"
        case .remote: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// How a tap on the map is interpreted.
enum MapTapMode: Equatable {
    case inspect
    case dropPin
    case addWaypoint
    case moveWaypoint(PersistentIdentifier)
}

@MainActor
@Observable
final class MainViewModel {
    var section: LibrarySection = .search
    var camera: MapCameraPosition = .region(.defaultTestRegion)
    var visibleRegion: MKCoordinateRegion?
    var previewPlace: PlaceResult?
    var tapMode: MapTapMode = .inspect
    var error: AppError?
    var editingRoute: TestRoute?

    private(set) var isConnecting = false

    /// Derived from the engine so the indicator never contradicts the transport.
    func status(engine: SimulationEngine) -> SessionStatus {
        if let failure = engine.lastError { return .error(failure.title) }
        if isConnecting { return .connecting }
        switch engine.phase {
        case .running: return .running
        case .paused: return .paused
        case .idle, .finished: return engine.fix == nil ? .disconnected : .connected
        }
    }

    func focus(on coordinate: CLLocationCoordinate2D, span: CLLocationDegrees = 0.02, animated: Bool = true) {
        let region = MKCoordinateRegion(center: coordinate,
                                        span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
        withAnimation(animated ? .easeInOut(duration: 0.35) : nil) {
            camera = .region(region)
        }
    }

    func frame(coordinates: [CLLocationCoordinate2D]) {
        guard let region = MKCoordinateRegion(fitting: coordinates) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(region)
        }
    }

    func present(_ error: AppError) {
        self.error = error
    }

    /// Brief connecting state so the indicator reflects work starting.
    func beginSession() async {
        isConnecting = true
        try? await Task.sleep(for: .milliseconds(250))
        isConnecting = false
    }
}

extension MKCoordinateRegion {
    static let defaultTestRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))

    init?(fitting coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.005))
        self.init(center: center, span: span)
    }
}
