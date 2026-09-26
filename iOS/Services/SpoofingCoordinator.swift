import Foundation
import Network

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

    /// What the last loopback probe saw, for diagnostics.
    private(set) var loopbackProbe = "not run"

    /// VPN-style interfaces and their IPv4 addresses — enough to tell whether
    /// LocalDevVPN/StosVPN is actually up, without any private data.
    var tunnelInterfaces: String {
        var found: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return "unknown" }
        defer { freeifaddrs(pointer) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec"),
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found.append("\(name)=\(String(cString: host))")
            }
        }
        return found.isEmpty ? "none" : found.joined(separator: ", ")
    }

    private let pathMonitor = NWPathMonitor()
    private let warnings = SpoofWarnings()
    /// Warned once per stretch on cellular, not on every location change.
    private var warnedForCellular = false

    // MARK: Holding the connection

    /// The location last put on the device, by a spoof or a route point.
    private var lastApplied: Spoofed?
    private var lastPushAt: Date?
    private var holdTask: Task<Void, Never>?
    /// The held connection died, and could not be reopened (on cellular it
    /// cannot be). Cleared by the next spoof that gets through.
    private(set) var heldConnectionLost = false

    /// Re-sends the current location every 4 seconds, as StikDebug does.
    ///
    /// iOS only lets the on-device connection be opened on Wi-Fi; one opened
    /// there keeps working on cellular, but an idle one lapses, and the next
    /// change then needs a new connection that cellular refuses. Keeping it
    /// busy — with the app kept alive by `BackgroundKeepAlive` — is what lets
    /// a spoof started at home be moved around anywhere.
    private func startHolding() {
        holdTask?.cancel()
        heldConnectionLost = false
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                guard !Task.isCancelled, !self.isWorking, self.hasPushedOnDevice,
                      let spot = self.lastApplied else { continue }
                // A route is streaming points already; do not fight it.
                if let lastPushAt = self.lastPushAt, Date.now.timeIntervalSince(lastPushAt) < 3 { continue }
                do {
                    try await self.onDevice().spoof(latitude: spot.latitude, longitude: spot.longitude)
                } catch {
                    // Stop rather than retry every 4 s: each failed open blocks
                    // for seconds. Coming back to Wi-Fi reopens it.
                    self.heldConnectionLost = true
                    self.lastOnDeviceFailure = error.localizedDescription
                    self.holdTask = nil
                    return
                }
            }
        }
    }

    private func stopHolding() {
        holdTask?.cancel()
        holdTask = nil
    }
    /// On cellular with no Wi-Fi, which changes what a dead loopback means.
    private(set) var isCellularOnly = false

    /// One instance, kept: it holds the open connection to this device, and
    /// rebuilding that per location change takes seconds.
    private var onDeviceSpoofing: OnDeviceSpoofing?
    private let keepAlive = BackgroundKeepAlive()

    init(pairingRecords: PairingRecordStore, client: RemoteControlClient) {
        self.pairingRecords = pairingRecords
        self.client = client
        self.loopbackAddress = UserDefaults.standard.string(forKey: "loopbackAddress")
            ?? OnDeviceSpoofing.defaultLoopbackAddress

        pairingRecords.onRecordChanged = { [weak self] in
            self?.releaseOnDeviceSession()
        }

        // Re-check the loopback the moment the network changes: on cellular
        // it only starts answering after Airplane Mode is toggled, and the
        // app should notice that by itself rather than wait for a poll.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cellularOnly = path.availableInterfaces.contains { $0.type == .cellular }
                && !path.availableInterfaces.contains { $0.type == .wifi }
            Task { @MainActor in
                guard let self else { return }
                // Moving onto cellular while holding a spoof: this is when
                // swiping the app away or Low Power Mode would cost it.
                if !cellularOnly { self.warnedForCellular = false }
                if cellularOnly, self.hasPushedOnDevice, !self.warnedForCellular {
                    self.warnedForCellular = true
                    self.warnings.cellularStarted()
                }
                self.isCellularOnly = cellularOnly
                // Back on Wi-Fi with a spoof whose connection was lost: open
                // a new one now, while iOS will allow it, so it is held again
                // before the phone goes back out.
                if !cellularOnly, self.heldConnectionLost, let spot = self.lastApplied {
                    await self.spoof(latitude: spot.latitude, longitude: spot.longitude, name: spot.name)
                }
                // Deliberately not closing the session: that would end a
                // spoof in force the moment you walk off Wi-Fi. A connection
                // the change really broke is rebuilt on the next use.
                await self.refreshLoopback()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    var route: Route {
        // On device when the loopback answers; the Mac when it does not and
        // the Mac is there to use.
        if pairingRecords.hasRecord, isLoopbackReachable { return .onDevice }
        if client.canSpoof { return .companion }
        // With no Mac, a record means the phone should try by itself anyway.
        // The probe can be wrong — it was on cellular — and a real attempt
        // either works or reports the actual error instead of a guess.
        if pairingRecords.hasRecord { return .onDevice }
        return .unavailable(client.unavailableReason
            ?? "Plug into the Mac and click Set Up iPhone Spoofing in the companion, or open the companion on this Wi-Fi.")
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

    /// What this app last put on the device, shown on the main screen.
    struct Spoofed: Equatable {
        var latitude: Double
        var longitude: Double
        var name: String?
    }

    private(set) var current: Spoofed?
    /// The last failure, by either route, for the main screen to show.
    var lastFailure: String? {
        didSet {
            guard let lastFailure else { return }
            failureLog.append("\(Date.now.formatted(date: .omitted, time: .standard)) [\(routeName)] \(lastFailure)")
            if failureLog.count > 10 { failureLog.removeFirst(failureLog.count - 10) }
        }
    }
    /// Recent failures, newest last, for Copy Diagnostics.
    private(set) var failureLog: [String] = []

    var routeName: String {
        switch route {
        case .onDevice: return "on-device"
        case .companion: return "mac"
        case .unavailable: return "unavailable"
        }
    }
    /// A change is on its way to the device.
    private(set) var isWorking = false

    func spoof(latitude: Double, longitude: Double, name: String?) async {
        isWorking = true
        defer { isWorking = false }
        switch route {
        case .onDevice:
            do {
                try await onDevice().spoof(latitude: latitude, longitude: longitude)
                hasPushedOnDevice = true
                keepAlive.start()
                lastApplied = Spoofed(latitude: latitude, longitude: longitude, name: name)
                startHolding()
                warnings.requestPermission()
                warnings.watchLowPower { [weak self] in self?.hasPushedOnDevice ?? false }
                if isCellularOnly, !warnedForCellular {
                    warnedForCellular = true
                    warnings.cellularStarted()
                }
                lastOnDeviceFailure = nil
                lastFailure = nil
                current = Spoofed(latitude: latitude, longitude: longitude, name: name)
            } catch {
                var message = error.localizedDescription
                if isCellularOnly {
                    message += "\n\niOS only lets this connection be opened on Wi-Fi. Spoof once while on Wi-Fi: the app then holds the connection, and you can change location anywhere — cellular included — for as long as it stays open."
                }
                lastOnDeviceFailure = message
                lastFailure = message
            }
        case .companion:
            if await client.setLocation(latitude: latitude, longitude: longitude, name: name) {
                lastFailure = nil
                current = Spoofed(latitude: latitude, longitude: longitude, name: name)
            } else {
                lastFailure = client.lastError ?? "The Mac companion did not apply the location."
            }
        case let .unavailable(reason):
            lastFailure = reason
        }
    }

    func clear() async {
        isCompanionPlayingRoute = false
        isWorking = true
        defer { isWorking = false }
        switch route {
        case .onDevice:
            do {
                try await onDevice().clear()
                hasPushedOnDevice = false
                keepAlive.stop()
                stopHolding()
                lastOnDeviceFailure = nil
                current = nil
            } catch {
                lastOnDeviceFailure = error.localizedDescription
                lastFailure = error.localizedDescription
            }
        case .companion:
            await client.clearLocation()
            if client.trouble == nil { current = nil } else { lastFailure = client.lastError }
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
    /// Where the device is being told it is: this app's last change, or what
    /// the Mac reports when the change was made there.
    var displayed: Spoofed? {
        if let status = client.status, route == .companion {
            return status.simulating
                ? Spoofed(latitude: status.latitude, longitude: status.longitude,
                          name: status.name.isEmpty ? nil : status.name)
                : nil
        }
        return current
    }

    var isSpoofing: Bool {
        if current != nil { return true }
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
            keepAlive.start()
            lastApplied = Spoofed(latitude: latitude, longitude: longitude, name: name)
            lastPushAt = .now
            if holdTask == nil { startHolding() }
        case .companion:
            await client.push(latitude: latitude, longitude: longitude, name: name)
        case .unavailable:
            break
        }
    }

    /// Checks the loopback VPN, so Settings can show its state rather than
    /// leaving it to be discovered by a failed spoof.
    func refreshLoopback() async {
        guard pairingRecords.hasRecord else {
            isLoopbackReachable = false
            return
        }
        let spoofer = onDevice()
        isLoopbackReachable = await spoofer.isLoopbackReachable()
        loopbackProbe = spoofer.lastProbe
        lastLoopbackCheck = .now
    }

    private var lastLoopbackCheck: Date?

    /// Re-checks the VPN when the last look is old enough to be worth
    /// repeating. Another app owns it and can switch it off at any time, but
    /// the check costs a connection attempt, so it is not done per call.
    func refreshLoopbackIfStale(after interval: TimeInterval = 10) async {
        guard pairingRecords.hasRecord else { return }
        if let lastLoopbackCheck, Date.now.timeIntervalSince(lastLoopbackCheck) < interval { return }
        await refreshLoopback()
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
        stopHolding()
        onDeviceSpoofing?.closeSession()
        onDeviceSpoofing = nil
        keepAlive.stop()
        hasPushedOnDevice = false
        current = nil
    }
}
