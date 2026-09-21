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

    var loopbackAddress: String {
        didSet { UserDefaults.standard.set(loopbackAddress, forKey: "loopbackAddress") }
    }

    init(pairingRecords: PairingRecordStore, client: RemoteControlClient) {
        self.pairingRecords = pairingRecords
        self.client = client
        self.loopbackAddress = UserDefaults.standard.string(forKey: "loopbackAddress")
            ?? OnDeviceSpoofing.defaultLoopbackAddress
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
        switch route {
        case .onDevice:
            do {
                try await onDevice().clear()
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

    /// Used while a route plays, where a failure per point would be noise.
    func push(latitude: Double, longitude: Double, name: String?) async {
        switch route {
        case .onDevice:
            try? await onDevice().spoof(latitude: latitude, longitude: longitude)
        case .companion:
            await client.push(latitude: latitude, longitude: longitude, name: name)
        case .unavailable:
            break
        }
    }

    private func onDevice() -> OnDeviceSpoofing {
        OnDeviceSpoofing(pairingRecordURL: PairingRecordStore.url,
                         loopbackAddress: loopbackAddress)
    }
}
