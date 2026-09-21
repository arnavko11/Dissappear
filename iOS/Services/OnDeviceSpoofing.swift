import Foundation

/// Spoofs this phone's location from the phone itself, with no computer.
///
/// It drives the same service the Mac companion does — Apple's developer
/// location service, `com.apple.dt.simulatelocation` behind DVT — but the
/// client runs here rather than on a Mac. Three things make that possible:
///
/// 1. **A pairing record.** iOS will not open its developer services to anyone
///    who cannot prove the device trusts them. That trust is established by a
///    computer, once, and exported as a file. It cannot be forged.
/// 2. **A loopback VPN.** An app may not reach its own device's services
///    directly, so a separate app (StosVPN or LocalDevVPN) publishes a local
///    address that routes back to this device. We connect to that.
/// 3. **idevice.** The Rust client, linked in, which speaks lockdown, RSD and
///    DVT well enough to ask for a coordinate to be simulated.
///
/// Nothing here is a jailbreak or a patch to iOS: it is the developer pathway
/// Apple ships, reached from this side of the cable instead of the other.
@MainActor
final class OnDeviceSpoofing {
    enum Failure: LocalizedError {
        case noPairingRecord
        case unreachable(String)
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .noPairingRecord:
                return "No pairing record has been imported. Export one from the Mac companion under Devices, then import it here."
            case let .unreachable(message):
                return "Could not reach this device's own services. Check that StosVPN (or LocalDevVPN) is connected. \(message)"
            case let .tool(message):
                return message
            }
        }
    }

    /// The address the loopback VPN publishes for this device. StosVPN's
    /// default is used unless the app is told otherwise, because a wrong
    /// guess here should be one field to correct rather than a new build.
    static let defaultLoopbackAddress = "10.7.0.1"

    private let pairingRecordURL: URL
    private let loopbackAddress: String

    init(pairingRecordURL: URL, loopbackAddress: String = OnDeviceSpoofing.defaultLoopbackAddress) {
        self.pairingRecordURL = pairingRecordURL
        self.loopbackAddress = loopbackAddress
    }

    /// Sets the coordinate the whole device reports.
    func spoof(latitude: Double, longitude: Double) async throws {
        try await withSession { client in
            try Self.check(location_simulation_set(client, latitude, longitude),
                           context: "Setting the location")
        }
    }

    /// Puts the real GPS back.
    func clear() async throws {
        try await withSession { client in
            try Self.check(location_simulation_clear(client), context: "Clearing the location")
        }
    }

    // MARK: - Session

    /// Opens the whole chain, runs `body`, and takes it down again.
    ///
    /// Each step owns a handle that must be freed even when a later step
    /// throws, so they are torn down in reverse on the way out.
    private func withSession(_ body: (OpaquePointer?) throws -> Void) async throws {
        guard FileManager.default.fileExists(atPath: pairingRecordURL.path) else {
            throw Failure.noPairingRecord
        }

        var pairing: OpaquePointer?
        try Self.check(idevice_pairing_file_read(pairingRecordURL.path, &pairing),
                       context: "Reading the pairing record")
        defer { idevice_pairing_file_free(pairing) }

        var provider: OpaquePointer?
        try withSocketAddress { address in
            try Self.check(idevice_tcp_provider_new(address, pairing, "Dissappear", &provider),
                           context: "Connecting to this device")
        }
        defer { idevice_provider_free(provider) }

        var proxy: OpaquePointer?
        try Self.check(core_device_proxy_connect(provider, &proxy),
                       context: "Opening the device proxy")
        defer { core_device_proxy_free(proxy) }

        // The adapter is a TCP stack in user space, so no tunnel interface and
        // no root are needed — which is the whole reason this can run inside
        // an ordinary sideloaded app.
        var adapter: OpaquePointer?
        try Self.check(core_device_proxy_create_tcp_adapter(proxy, &adapter),
                       context: "Creating the tunnel")
        defer { adapter_free(adapter) }

        var rsdPort: UInt16 = 0
        try Self.check(core_device_proxy_get_server_rsd_port(proxy, &rsdPort),
                       context: "Finding the service port")

        var stream: OpaquePointer?
        try Self.check(adapter_connect(adapter, rsdPort, &stream),
                       context: "Connecting to the service port")

        var handshake: OpaquePointer?
        try Self.check(rsd_handshake_new(stream, &handshake),
                       context: "Handshaking with the device")
        defer { rsd_handshake_free(handshake) }

        var server: OpaquePointer?
        try Self.check(remote_server_connect_rsd(adapter, handshake, &server),
                       context: "Opening the developer server")
        defer { remote_server_free(server) }

        var client: OpaquePointer?
        try Self.check(location_simulation_new(server, &client),
                       context: "Opening the location service")
        defer { location_simulation_free(client) }

        try body(client)
    }

    /// Builds the `sockaddr_in` for the loopback VPN's address.
    private func withSocketAddress(_ body: (UnsafePointer<sockaddr>) throws -> Void) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(62078).bigEndian    // lockdownd
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        guard inet_pton(AF_INET, loopbackAddress, &address.sin_addr) == 1 else {
            throw Failure.unreachable("\(loopbackAddress) is not a valid address.")
        }

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0) }
        }
    }

    /// Turns idevice's error pointer into a thrown Swift error, freeing it.
    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, context: String) throws {
        guard let error else { return }
        let message = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
        let code = error.pointee.code
        idevice_error_free(error)

        // A refused connection here is almost always the loopback VPN being
        // off, rather than anything wrong with the device or the request.
        if context.contains("Connecting") {
            throw Failure.unreachable("\(context) failed: \(message) (\(code))")
        }
        throw Failure.tool("\(context) failed: \(message) (\(code))")
    }
}
