import Foundation
import Network

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
        case noLoopback(String)
        case recordRejected(String)
        case unreachable(String)
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .noPairingRecord:
                return "No pairing record has been imported. Export one from the Mac companion under Devices, then import it here."
            case let .recordRejected(detail):
                return """
                The iPhone hung up on this app, so it would not open a session \
                with the imported pairing record. In order:

                1. Plug the iPhone into the Mac with Dissappear Companion open \
                (latest version) for a few seconds. It switches on network \
                connections, which the loopback VPN needs — the usual cause.
                2. Keep the iPhone unlocked and try again.
                3. Still failing: Export Pairing Record on the Mac again, tap \
                Trust, and import the new file here.

                \(detail)
                """
            case let .noLoopback(address):
                return "Nothing is answering at \(address). Install StosVPN or LocalDevVPN — separate apps, not part of this one — and switch the VPN on. iOS will not let this app reach its own device's services without one."
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

    /// lockdownd's port, which the loopback VPN routes back to this device.
    static let lockdownPort: UInt16 = 62078

    private let pairingRecordURL: URL
    private let loopbackAddress: String

    /// The open chain, kept between calls.
    ///
    /// Building it takes seconds — a lockdown connection, a tunnel and an RSD
    /// handshake — so doing it per coordinate made a route impossible and
    /// every change sluggish. It is torn down on failure and rebuilt.
    private var session: Session?
    private var heartbeat: Heartbeat?

    private struct Session {
        var provider: OpaquePointer?
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        var server: OpaquePointer?
        var client: OpaquePointer?

        func close() {
            // Reverse order, and only the handles idevice did not take.
            location_simulation_free(client)
            remote_server_free(server)
            rsd_handshake_free(handshake)
            adapter_free(adapter)
            idevice_provider_free(provider)
        }
    }

    init(pairingRecordURL: URL, loopbackAddress: String = OnDeviceSpoofing.defaultLoopbackAddress) {
        self.pairingRecordURL = pairingRecordURL
        self.loopbackAddress = loopbackAddress
    }

    /// Whether the loopback VPN is up and lockdownd is answering through it.
    ///
    /// Worth its own check: without it every failure below looks the same, and
    /// the commonest cause by far is simply that the VPN is switched off.
    func isLoopbackReachable() async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(loopbackAddress),
                port: NWEndpoint.Port(rawValue: Self.lockdownPort) ?? 62078,
                using: .tcp)

            let finished = OnceFlag()
            let settle: @Sendable (Bool) -> Void = { reachable in
                guard finished.claim() else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: settle(true)
                case .failed, .cancelled: settle(false)
                case .waiting: settle(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: .seconds(3))
                settle(false)
            }
        }
    }

    /// Sets the coordinate the whole device reports.
    func spoof(latitude: Double, longitude: Double) async throws {
        try await onOpenSession { client in
            try Self.check(location_simulation_set(client, latitude, longitude),
                           context: "Setting the location")
        }
    }

    /// Puts the real GPS back, and lets the session go.
    func clear() async throws {
        defer { closeSession() }
        try await onOpenSession { client in
            try Self.check(location_simulation_clear(client), context: "Clearing the location")
        }
    }

    /// Drops the held session, so the next call builds a fresh one.
    func closeSession() {
        session?.close()
        session = nil
        heartbeat?.stop()
        heartbeat = nil
    }

    /// Runs `body` against the open session, opening one if needed.
    ///
    /// A session can go stale — the VPN drops, the device sleeps — and the
    /// failure only shows up on use, so a first failure closes it and tries
    /// once more with a new one rather than surfacing an error that a retry
    /// would have fixed.
    private func onOpenSession(_ body: (OpaquePointer?) throws -> Void) async throws {
        if session == nil { try await openSession() }

        do {
            try body(session?.client)
        } catch {
            closeSession()
            try await openSession()
            try body(session?.client)
        }
    }

    // MARK: - Session

    /// Opens the whole chain and keeps it.
    ///
    /// Ownership follows idevice's C API, which moves some handles and
    /// borrows others. Freeing a moved handle is a double free and reading
    /// one is a use-after-free, so each is noted where it happens. On the way
    /// out through a failure, only what has actually been built is released.
    private func openSession() async throws {
        guard FileManager.default.fileExists(atPath: pairingRecordURL.path) else {
            throw Failure.noPairingRecord
        }
        guard await isLoopbackReachable() else {
            throw Failure.noLoopback(loopbackAddress)
        }

        // The heartbeat first: it is the smallest thing that needs a
        // lockdown session, so if the phone will not accept this record, the
        // failure is named here rather than three steps later.
        let beat = Heartbeat()
        do {
            try await beat.start(pairingRecordPath: pairingRecordURL.path, address: try socketAddress())
        } catch let failure as HeartbeatError {
            throw Self.classify("Starting a lockdown session failed: \(failure.message)")
        }
        heartbeat?.stop()
        heartbeat = beat

        var partial = Session()
        // Anything built before a throw still has to be released; success
        // hands the whole lot to `session` and clears this.
        var keep = false
        defer { if !keep { partial.close() } }

        var pairing: OpaquePointer?
        try Self.check(idevice_pairing_file_read(pairingRecordURL.path, &pairing),
                       context: "Reading the pairing record")

        var providerError: UnsafeMutablePointer<IdeviceFfiError>?
        try withSocketAddress { address in
            // The provider takes the pairing file, success or failure, so it
            // is not ours to free from here on.
            providerError = idevice_tcp_provider_new(address, pairing, "Dissappear", &partial.provider)
        }
        try Self.check(providerError, context: "Connecting to this device")

        var proxy: OpaquePointer?
        try Self.check(core_device_proxy_connect(partial.provider, &proxy),
                       context: "Opening the device proxy")

        // Read the port before the adapter is made: creating the adapter
        // takes the proxy, and reading it afterwards is a use-after-free.
        var rsdPort: UInt16 = 0
        do {
            try Self.check(core_device_proxy_get_server_rsd_port(proxy, &rsdPort),
                           context: "Finding the service port")
        } catch {
            core_device_proxy_free(proxy)
            throw error
        }

        // A userspace TCP stack, so no tunnel interface and no root — the
        // whole reason this can run inside an ordinary sideloaded app. It
        // takes the proxy with it.
        try Self.check(core_device_proxy_create_tcp_adapter(proxy, &partial.adapter),
                       context: "Creating the tunnel")

        var stream: OpaquePointer?
        try Self.check(adapter_connect(partial.adapter, rsdPort, &stream),
                       context: "Connecting to the service port")

        // The handshake takes the stream.
        try Self.check(rsd_handshake_new(stream, &partial.handshake),
                       context: "Handshaking with the device")

        // Borrows the adapter and the handshake, so both are still ours.
        try Self.check(remote_server_connect_rsd(partial.adapter, partial.handshake, &partial.server),
                       context: "Opening the developer server")

        try Self.check(location_simulation_new(partial.server, &partial.client),
                       context: "Opening the location service")

        keep = true
        session = partial
    }

    /// The `sockaddr_in` for the loopback VPN's address.
    private func socketAddress() throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.lockdownPort.bigEndian   // lockdownd
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        guard inet_pton(AF_INET, loopbackAddress, &address.sin_addr) == 1 else {
            throw Failure.unreachable("\(loopbackAddress) is not a valid address.")
        }
        return address
    }

    private func withSocketAddress(_ body: (UnsafePointer<sockaddr>) throws -> Void) throws {
        var address = try socketAddress()
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0) }
        }
    }

    /// Guards a continuation so it can only be resumed once.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Turns idevice's error pointer into a thrown Swift error, freeing it.
    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, context: String) throws {
        guard let error else { return }
        let message = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
        let code = error.pointee.code
        idevice_error_free(error)

        throw classify("\(context) failed: \(message) (\(code))")
    }

    /// Picks the explanation that fits an idevice failure.
    private static func classify(_ detail: String) -> Failure {
        let lower = detail.lowercased()

        // A broken pipe means the device accepted the connection and then hung
        // up, which is lockdownd refusing the session rather than anything
        // wrong with the network — so saying "could not reach" would send the
        // user looking in the wrong place entirely.
        if lower.contains("broken pipe") || lower.contains("os code 32")
            || lower.contains("connection reset") || lower.contains("eof") {
            return Failure.recordRejected(detail)
        }

        // A refused connection is almost always the loopback VPN being off.
        if lower.contains("connecting") || lower.contains("refused") {
            return Failure.unreachable(detail)
        }
        return Failure.tool(detail)
    }
}
