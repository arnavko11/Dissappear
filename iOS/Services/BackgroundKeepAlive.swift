import CoreLocation

/// Keeps the app alive in the background while it spoofs this phone itself.
///
/// On-device spoofing lasts exactly as long as this app's connection to the
/// device. A suspended app stops answering lockdownd's heartbeat, the device
/// drops the connection, and the real location comes back the moment you
/// switch to the app you were spoofing for. Background location updates are
/// the sanctioned way to keep running; the blue status-bar pill that comes
/// with them is honest about it. Coarse accuracy keeps the battery cost low.
@MainActor
final class BackgroundKeepAlive {
    private let manager = CLLocationManager()
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isActive = false
    }
}
