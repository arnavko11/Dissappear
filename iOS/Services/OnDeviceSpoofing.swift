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
/// 3. **idevice.** The Rust client, linked in, which speaks RemotePairing, RSD and
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
                return "Not set up yet. Plug this iPhone into the Mac, click Set Up iPhone Spoofing in the companion (Devices), and tap Trust."
            case let .recordRejected(detail):
                return """
                \(detail)

                The iPhone refused this pairing record. Plug it into the Mac, \
                click Set Up iPhone Spoofing in the companion (Devices), tap \
                Trust, then try again here. Records expire after an iOS \
                update or reset.
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

    /// remotepairingd's port. Lockdown (62078) is the obvious door and the
    /// wrong one: over the loopback VPN, lockdownd hangs up on CoreDeviceProxy
    /// with a broken pipe. RemotePairing here is what StikDebug and iloader
    /// use, and it reaches the same developer services.
    static let pairingPort: UInt16 = 49152

    private let pairingRecordURL: URL
    private let loopbackAddress: String

    /// The open chain, kept between calls.
    ///
    /// Building it takes seconds — pair-verify, a tunnel and an RSD
    /// handshake — so doing it per coordinate made a route impossible and
    /// every change sluggish. It is torn down on failure and rebuilt.
    private var session: Session?

    private struct Session {
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
        }
    }

    init(pairingRecordURL: URL, loopbackAddress: String = OnDeviceSpoofing.defaultLoopbackAddress) {
        self.pairingRecordURL = pairingRecordURL
        self.loopbackAddress = loopbackAddress
    }

    /// Whether anything answers at the loopback address, and what happened.
    ///
    /// A plain BSD socket, the same kind the Rust tunnel connects with. The
    /// check used to be an NWConnection, which applies iOS's per-app network
    /// policy and parks in `.waiting` on cellular — so it reported the VPN
    /// as down on cellular while the real connection would have gone through.
    func isLoopbackReachable() async -> Bool {
        let address = loopbackAddress
        let port = Self.pairingPort
        let result = await Task.detached(priority: .userInitiated) {
            Self.probe(address: address, port: port)
        }.value
        lastProbe = result.detail
        return result.reachable
    }

    /// What the last reachability probe saw, for diagnostics.
    private(set) var lastProbe = "not run"

    /// What a probe result means, in the user's terms.
    nonisolated static func meaning(of detail: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("refused") {
            return "The VPN is routing, but the iPhone's pairing service refused: iOS only accepts new connections to it on Wi-Fi. Spoof once on Wi-Fi and the app holds that connection — after that you can change location on cellular too, as long as the app keeps running."
        }
        if lower.contains("timed out") || lower.contains("unreachable") || lower.contains("no route") {
            return "Nothing is routing to that address: the VPN is off or not passing traffic. Switch LocalDevVPN/StosVPN off and on, or toggle Airplane Mode with it on."
        }
        if lower.contains("connected") {
            return "The address answers now; try again."
        }
        return ""
    }

    nonisolated static func probe(address: String, port: UInt16) -> (reachable: Bool, detail: String) {
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else {
            return (false, "\(address) is not a valid address")
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return (false, "socket: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return (true, "connected") }
        guard errno == EINPROGRESS else {
            return (false, "connect: \(String(cString: strerror(errno)))")
        }

        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&waiting, 1, 3000)
        guard ready > 0 else {
            return (false, ready == 0 ? "timed out after 3 s" : "poll: \(String(cString: strerror(errno)))")
        }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0 ? (true, "connected") : (false, String(cString: strerror(failure)))
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
        // No pre-check here: the tunnel's own connect reports the real
        // error, which a probe can only guess at.

        var partial = Session()
        // Anything built before a throw still has to be released; success
        // hands the whole lot to `session` and clears this.
        var keep = false
        defer { if !keep { partial.close() } }

        var pairing: OpaquePointer?
        try Self.check(rp_pairing_file_read(pairingRecordURL.path, &pairing),
                       context: "Reading the pairing record")
        // Borrowed by the tunnel, so still ours to free.
        defer { rp_pairing_file_free(pairing) }

        // Pair-verify with the record, then a userspace tunnel with the RSD
        // handshake done — no root and no tunnel interface, in one call.
        var tunnelError: UnsafeMutablePointer<IdeviceFfiError>?
        try withSocketAddress { address in
            tunnelError = tunnel_create_rppairing(address, socklen_t(MemoryLayout<sockaddr_in>.size),
                                                  "Dissappear", pairing, nil, nil,
                                                  &partial.adapter, &partial.handshake)
        }
        do {
            try Self.check(tunnelError, context: "Opening the tunnel")
        } catch {
            // idevice reports a failed connect as "device socket io failed"
            // and drops the errno, which is the one thing that says whether
            // the VPN is down (timed out / unreachable) or the phone's pairing
            // service is not listening (refused). Probe once and say which.
            let probe = Self.probe(address: loopbackAddress, port: Self.pairingPort)
            lastProbe = probe.detail
            throw Failure.tool("\(error.localizedDescription)\n\nSocket check on \(loopbackAddress):\(Self.pairingPort): \(probe.detail). \(Self.meaning(of: probe.detail))")
        }

        // Borrows the adapter and the handshake, so both are still ours.
        try Self.check(remote_server_connect_rsd(partial.adapter, partial.handshake, &partial.server),
                       context: "Opening the developer server")

        // Borrows the server, which therefore has to outlive the client.
        try Self.check(location_simulation_new(partial.server, &partial.client),
                       context: "Opening the location service")

        keep = true
        session = partial
    }

    /// The `sockaddr_in` for the loopback VPN's address.
    private func socketAddress() throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.pairingPort.bigEndian
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
        // up, which is the device refusing the session rather than anything
        // wrong with the network — so saying "could not reach" would send the
        // user looking in the wrong place entirely.
        if lower.contains("broken pipe") || lower.contains("os code 32")
            || lower.contains("connection reset") || lower.contains("eof") {
            return Failure.recordRejected(detail)
        }
        if lower.contains("verify") || lower.contains("not paired") || lower.contains("unauthori")
            || lower.contains("signature") || lower.contains("missing field") {
            return Failure.recordRejected(detail)
        }

        // A refused connection is almost always the loopback VPN being off.
        if lower.contains("connecting") || lower.contains("refused") {
            return Failure.unreachable(detail)
        }
        return Failure.tool(detail)
    }
}
