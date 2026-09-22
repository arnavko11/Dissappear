import Foundation

/// Decides which way a location change reaches the device.
///
/// There are two, and they are not equivalent:
///
/// - **On device.** The phone drives its own developer services. Works
///   anywhere, including out of the house, because nothing else is involved.
///   Needs a pairing record and a loopback VPN.
/// - **Through the Mac companion.** Works only while the Mac can reach the
///   phone, over USB or the same network.
///
/// On device is preferred whenever it is set up, because the companion cannot
/// follow you out of the door.
@MainActor
@Observable
final class SpoofingCoordinator {
    enum Route: Equatable {
        case onDevice
        case companion
        case unavailable(String)
    }

    private let pairingRecords: PairingRecordStore
    private let client: RemoteControlClient

    /// Set when the last on-device attempt failed, so the UI can say why
    /// rather than silently falling back and looking like it did nothing.
    private(set) var lastOnDeviceFailure: String?
    /// Whether the loopback VPN is answering, refreshed when Settings is open.
    private(set) var isLoopbackReachable = false

    var loopbackAddress: String {
        didSet {
            UserDefaults.standard.set(loopbackAddress, forKey: "loopbackAddress")
            // The held session points at the old address.
            onDeviceSpoofing?.closeSession()
            onDeviceSpoofing = nil
        }
    }

    /// One instance, kept: it holds the open connection to this device, and
    /// rebuilding that per location change takes seconds.
    private var onDeviceSpoofing: OnDeviceSpoofing?

    init(pairingRecords: PairingRecordStore, client: RemoteControlClient) {
        self.pairingRecords = pairingRecords
        self.client = client
        self.loopbackAddress = UserDefaults.standard.string(forKey: "loopbackAddress")
            ?? OnDeviceSpoofing.defaultLoopbackAddress

        pairingRecords.onRecordChanged = { [weak self] in
            self?.releaseOnDeviceSession()
        }
    }

    var route: Route {
        if pairingRecords.hasRecord { return .onDevice }
        if client.canSpoof { return .companion }
        return .unavailable(client.unavailableReason
            ?? "Import a pairing record, or pair the Mac companion.")
    }

    var canSpoof: Bool {
        if case .unavailable = route { return false }
        return true
    }

    /// Why nothing can be spoofed, or nil when something can.
    var unavailableReason: String? {
        if case let .unavailable(reason) = route { return reason }
        return nil
    }

    func spoof(latitude: Double, longitude: Double, name: String?) async {
        switch route {
        case .onDevice:
            do {
                try await onDevice().spoof(latitude: latitude, longitude: longitude)
                hasPushedOnDevice = true
                lastOnDeviceFailure = nil
            } catch {
                lastOnDeviceFailure = error.localizedDescription
            }
        case .companion:
            await client.setLocation(latitude: latitude, longitude: longitude, name: name)
        case .unavailable:
            break
        }
    }

    func clear() async {
        isCompanionPlayingRoute = false
        switch route {
        case .onDevice:
            do {
                try await onDevice().clear()
                hasPushedOnDevice = false
                lastOnDeviceFailure = nil
            } catch {
                lastOnDeviceFailure = error.localizedDescription
            }
        case .companion:
            await client.clearLocation()
        case .unavailable:
            break
        }
    }

    /// True while the companion is replaying a route by itself, so nothing
    /// else pushes coordinates over the top of it.
    private(set) var isCompanionPlayingRoute = false

    /// Whether a location is currently in force on the device, by either
    /// route. Stopping has to stay available even when the local clock is
    /// idle, because the device can be spoofed without one running.
    var isSpoofing: Bool {
        if isCompanionPlayingRoute { return true }
        if client.status?.simulating == true { return true }
        return hasPushedOnDevice
    }

    /// Set once this phone has applied a location to itself, since nothing
    /// else reports that state back.
    private var hasPushedOnDevice = false

    /// Starts a route the best way the current route allows.
    ///
    /// Through the companion a whole track is handed over and replayed in one
    /// session; on device the points are streamed, which is affordable there
    /// because the connection is held open between them.
    ///
    /// Returns true when the companion took the whole route, so the caller
    /// knows the points do not need streaming.
    @discardableResult
    func startRoute(name: String, waypoints: [(latitude: Double, longitude: Double)],
                    speed: Double, loops: Bool) async -> Bool {
        guard case .companion = route, waypoints.count > 1 else {
            isCompanionPlayingRoute = false
            return false
        }
        let accepted = await client.playRoute(name: name, waypoints: waypoints,
                                              speed: speed, loops: loops)
        isCompanionPlayingRoute = accepted
        return accepted
    }

    /// Used while a route plays, where a failure per point would be noise.
    func push(latitude: Double, longitude: Double, name: String?) async {
        switch route {
        case .onDevice:
            try? await onDevice().spoof(latitude: latitude, longitude: longitude)
            hasPushedOnDevice = true
        case .companion:
            await client.push(latitude: latitude, longitude: longitude, name: name)
        case .unavailable:
            break
        }
    }

    /// Checks the loopback VPN, so Settings can show its state rather than
    /// leaving it to be discovered by a failed spoof.
    func refreshLoopback() async {
        guard pairingRecords.hasRecord else { return }
        isLoopbackReachable = await onDevice().isLoopbackReachable()
    }

    private func onDevice() -> OnDeviceSpoofing {
        if let onDeviceSpoofing { return onDeviceSpoofing }
        let created = OnDeviceSpoofing(pairingRecordURL: PairingRecordStore.url,
                                       loopbackAddress: loopbackAddress)
        onDeviceSpoofing = created
        return created
    }

    /// Lets the device connection go, for when the record changes or the app
    /// is put away.
    func releaseOnDeviceSession() {
        onDeviceSpoofing?.closeSession()
        onDeviceSpoofing = nil
    }
}
