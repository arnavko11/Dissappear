import MapKit
import Observation

@MainActor
@Observable
final class LocationSearchViewModel {
    var query = ""
    var manualLatitude = ""
    var manualLongitude = ""
    private(set) var results: [PlaceResult] = []
    private(set) var isResolving = false

    let service: LocationSearchService
    private var debounceTask: Task<Void, Never>?
    private var region: MKCoordinateRegion?

    init(service: LocationSearchService) {
        self.service = service
    }

    var completions: [MKLocalSearchCompletion] { service.completions }
    var failure: String? { service.failure }

    /// A coordinate typed straight into the search field.
    var parsedCoordinate: CLLocationCoordinate2D? { CoordinateParser.parse(query) }

    var manualCoordinate: CLLocationCoordinate2D? {
        guard let latitude = Double(manualLatitude.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(manualLongitude.trimmingCharacters(in: .whitespaces)),
              RouteMath.isValid(latitude: latitude, longitude: longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var manualEntryHasInput: Bool {
        !manualLatitude.isEmpty || !manualLongitude.isEmpty
    }

    func updateRegion(_ region: MKCoordinateRegion?) {
        self.region = region
    }

    func reset() {
        query = ""
        results = []
        manualLatitude = ""
        manualLongitude = ""
        service.clear()
    }

    func submit() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let coordinate = parsedCoordinate {
            results = [PlaceResult(name: "Coordinate",
                                   address: CoordinateParser.format(coordinate),
                                   coordinate: coordinate)]
            return
        }
        isResolving = true
        results = await service.search(query: trimmed, region: region)
        isResolving = false
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> PlaceResult? {
        isResolving = true
        defer { isResolving = false }
        return await service.resolve(completion)
    }

    /// Called by the view when the query field changes.
    func queryDidChange() {
        scheduleCompletion()
    }

    private func scheduleCompletion() {
        debounceTask?.cancel()
        let current = query
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.service.updateQuery(current, region: self.region)
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.results = []
            }
        }
    }
}
