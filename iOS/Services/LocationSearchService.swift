import CoreLocation
import MapKit
import Observation

struct PlaceResult: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: PlaceResult, rhs: PlaceResult) -> Bool { lhs.id == rhs.id }
}

/// Wraps MapKit local search. Completions update as the user types; resolving a
/// completion or a free-form query yields coordinates.
@MainActor
@Observable
final class LocationSearchService {
    private(set) var completions: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false
    private(set) var failure: String?

    private let completer = MKLocalSearchCompleter()
    private let completerDelegate = CompleterDelegate()

    init() {
        completer.resultTypes = [.address, .pointOfInterest, .query]
        completer.delegate = completerDelegate
        completerDelegate.onResults = { [weak self] results in
            self?.completions = results
            self?.failure = nil
        }
        completerDelegate.onFailure = { [weak self] message in
            self?.completions = []
            self?.failure = message
        }
    }

    func updateQuery(_ query: String, region: MKCoordinateRegion?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else {
            completions = []
            failure = nil
            return
        }
        if let region { completer.region = region }
        completer.queryFragment = trimmed
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> PlaceResult? {
        await search(request: MKLocalSearch.Request(completion: completion)).first
    }

    /// Free-form search used when the user submits the field directly.
    func search(query: String, region: MKCoordinateRegion?) async -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        return await search(request: request)
    }

    private func search(request: MKLocalSearch.Request) async -> [PlaceResult] {
        isSearching = true
        defer { isSearching = false }
        do {
            let response = try await MKLocalSearch(request: request).start()
            failure = nil
            return response.mapItems.map { item in
                PlaceResult(name: item.name ?? "Dropped Pin",
                            address: item.placemark.formattedAddress,
                            coordinate: item.placemark.coordinate)
            }
        } catch {
            failure = "Search failed. \(error.localizedDescription)"
            return []
        }
    }

    func clear() {
        completions = []
        failure = nil
    }

    /// Reverse geocodes a dropped pin so it can be saved with a readable name.
    func describe(_ coordinate: CLLocationCoordinate2D) async -> PlaceResult {
        let fallback = PlaceResult(name: "Dropped Pin",
                                   address: CoordinateParser.format(coordinate),
                                   coordinate: coordinate)
        let placemarks = try? await CLGeocoder()
            .reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard let placemark = placemarks?.first else { return fallback }
        return PlaceResult(name: placemark.name ?? fallback.name,
                           address: placemark.formattedAddress,
                           coordinate: coordinate)
    }
}

private final class CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
    var onResults: (([MKLocalSearchCompletion]) -> Void)?
    var onFailure: ((String) -> Void)?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults?(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onFailure?("Search suggestions are unavailable. \(error.localizedDescription)")
    }
}

extension CLPlacemark {
    var formattedAddress: String {
        let street = [subThoroughfare, thoroughfare].compactMap { $0 }.joined(separator: " ")
        return [street, locality, administrativeArea, postalCode, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

enum CoordinateParser {
    /// Accepts "30.2672, -97.7431" and "30.2672 -97.7431".
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
        guard parts.count == 2, RouteMath.isValid(latitude: parts[0], longitude: parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    static func format(_ coordinate: CLLocationCoordinate2D, precision: Int = 4) -> String {
        String(format: "%.\(precision)f, %.\(precision)f", coordinate.latitude, coordinate.longitude)
    }
}
