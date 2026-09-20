import CoreLocation
import Foundation

protocol LocationProviding: AnyObject {
    var latest: CLLocation? { get }
}

/// Wraps Core Location for side-by-side comparison with simulated fixes.
/// Authorization is requested through the standard system prompt.
final class SystemLocationProvider: NSObject, ObservableObject, LocationProviding, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        latest = nil
    }
}
