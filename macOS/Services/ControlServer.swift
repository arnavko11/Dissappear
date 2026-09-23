import Foundation
import Network

/// A small HTTP server on the local network so the iOS app can steer the
/// simulated location while the Mac holds the developer session open.
///
/// It listens only on the local network, every request must carry the code a
/// phone is given when someone at the Mac approves it, and it exposes nothing
/// but the location
/// controls. It runs by default, because steering the spoofed location from
/// the phone is the point of the companion; Settings can switch it off.
final class ControlServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var body: Data
    }

    struct Response {
        var status: Int
        var json: [String: Any]

        static func ok(_ json: [String: Any]) -> Response { Response(status: 200, json: json) }
        static func error(_ status: Int, _ message: String) -> Response {
            Response(status: status, json: ["error": message])
        }
    }

    private let queue = DispatchQueue(label: "com.dissappear.companion.control")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    /// Bonjour type the iOS app browses for, so neither end needs an address.
    static let serviceType = "_dissappear._tcp"

    /// Kept across launches so a paired phone does not have to be paired
    /// again every time the companion restarts.
    private static let pairingCodeKey = "controlServer.pairingCode"

    private var failedAttempts = 0
    private var storedPairingCode = ""
    private var storedPort: UInt16 = 0

    var pairingCode: String {
        lock.lock(); defer { lock.unlock() }
        return storedPairingCode
    }

    var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return storedPort
    }

    var handler: (@Sendable (Request) async -> Response)?

    /// Called when the listener becomes ready or fails. `start()` returning
    /// only means the listener was created, so the UI waits for this rather
    /// than claiming to be listening before it is.
    var onStateChange: (@Sendable (Result<UInt16, Error>) -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    /// Addresses the phone can be pointed at.
    static func localAddresses() -> [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let name = String(cString: host)
                if !name.isEmpty, !addresses.contains(name) { addresses.append(name) }
            }
        }
        return addresses
    }

    func start(preferredPort: UInt16 = 8787) throws {
        stop()

        let defaults = UserDefaults.standard
        let existing = defaults.string(forKey: Self.pairingCodeKey) ?? ""
        let code = existing.count == 8 ? existing : Self.makePairingCode()
        defaults.set(code, forKey: Self.pairingCodeKey)

        lock.lock()
        storedPairingCode = code
        lock.unlock()

        try listen(on: preferredPort, allowFallback: true)
    }

    /// Replaces the pairing code, so a code shared earlier stops working.
    func rotatePairingCode() {
        let code = Self.makePairingCode()
        UserDefaults.standard.set(code, forKey: Self.pairingCodeKey)
        lock.lock()
        storedPairingCode = code
        lock.unlock()
    }

    /// Backs off after repeated wrong codes, up to two seconds.
    private func noteFailedAttempt() {
        lock.lock(); defer { lock.unlock() }
        failedAttempts = min(failedAttempts + 1, 20)
    }

    private func clearFailedAttempts() {
        lock.lock(); defer { lock.unlock() }
        failedAttempts = 0
    }

    private var failureDelayMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }
        return min(2_000, failedAttempts * 100)
    }

    /// Unambiguous characters only: this gets typed on a phone.
    private static func makePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement() ?? "A" })
    }

    /// `allowFallback` retries once on a kernel-assigned port, so another
    /// process already holding 8787 cannot leave the server silently dead —
    /// the old code reported success and then never listened.
    private func listen(on preferredPort: UInt16, allowFallback: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let endpoint = preferredPort == 0
            ? NWEndpoint.Port.any
            : (NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        let listener = try NWListener(using: parameters, on: endpoint)

        // Announce over Bonjour so the phone can find this Mac by itself.
        // Bonjour instance names are limited to 63 bytes; a long computer
        // name would have been rejected outright, taking discovery with it.
        let advertised = (Host.current().localizedName ?? "Dissappear Companion")
            .replacingOccurrences(of: ".", with: " ")
        listener.service = NWListener.Service(name: String(advertised.prefix(60)),
                                              type: Self.serviceType)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let assigned = listener.port?.rawValue ?? preferredPort
                self.lock.lock()
                let isCurrent = self.listener === listener
                if isCurrent { self.storedPort = assigned }
                self.lock.unlock()
                if isCurrent { self.onStateChange?(.success(assigned)) }

            case let .failed(error):
                self.handleFailure(error, listener: listener,
                                   preferredPort: preferredPort, allowFallback: allowFallback)

            case let .waiting(error) where Self.isFatal(error):
                self.handleFailure(error, listener: listener,
                                   preferredPort: preferredPort, allowFallback: allowFallback)

            default:
                break
            }
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    private func handleFailure(_ error: NWError,
                               listener: NWListener,
                               preferredPort: UInt16,
                               allowFallback: Bool) {
        lock.lock()
        let isCurrent = self.listener === listener
        lock.unlock()
        guard isCurrent else { return }
        stop()

        if allowFallback, preferredPort != 0 {
            do { try listen(on: 0, allowFallback: false) }
            catch { onStateChange?(.failure(error)) }
        } else {
            onStateChange?(.failure(error))
        }
    }

    /// A busy port surfaces as `.waiting(POSIXErrorCode: Address already in use)`
    /// and never resolves itself, so it is treated as a failure to retry.
    private static func isFatal(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EADDRINUSE || code == .EACCES || code == .EADDRNOTAVAIL
        }
        return false
    }

    func stop() {
        lock.lock()
        let existing = listener
        let open = connections
        listener = nil
        connections = [:]
        lock.unlock()

        existing?.cancel()
        open.values.forEach { $0.cancel() }

        lock.lock()
        storedPort = 0
        lock.unlock()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if error != nil || (isComplete && accumulated.isEmpty) {
                self.close(connection)
                return
            }

            guard let parsed = Self.parse(accumulated) else {
                if accumulated.count > 1_000_000 { self.close(connection); return }
                self.receive(on: connection, buffer: accumulated)   // wait for the rest
                return
            }

            Task {
                let response = await self.respond(to: parsed.request, headers: parsed.headers)
                self.send(response, on: connection)
            }
        }
    }

    /// Asks whoever is at the Mac whether a phone may pair. The phone finds
    /// this Mac by itself and asks; nobody types an address or a code.
    var onPairRequest: (@Sendable (String) async -> Bool)?

    private var isPairPending = false

    private func claimPairSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isPairPending { return false }
        isPairPending = true
        return true
    }

    private func releasePairSlot() {
        lock.lock(); isPairPending = false; lock.unlock()
    }

    /// The one request that needs no code, because it is how a phone gets
    /// one. It hands the code over only after a person at the Mac says yes,
    /// and one prompt at a time, so the network cannot spam the screen.
    private func pair(_ request: Request) async -> Response {
        guard let onPairRequest else { return .error(503, "The companion is not ready.") }
        guard claimPairSlot() else {
            return .error(429, "Another iPhone is already waiting for approval on the Mac.")
        }
        defer { releasePairSlot() }

        let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let name = String((payload?["name"] as? String ?? "An iPhone").prefix(60))
        guard await onPairRequest(name) else {
            return .error(403, "Declined on the Mac.")
        }
        return .ok(["code": pairingCode])
    }

    private func respond(to request: Request, headers: [String: String]) async -> Response {
        if request.method == "POST", request.path == "/pair" {
            return await pair(request)
        }
        let expected = pairingCode
        guard !expected.isEmpty, headers["x-pair-code"] == expected else {
            // Slow a wrong code down. The code is long enough that guessing
            // it is not realistic, but anything on the network can reach this
            // port, and an unthrottled guess loop costs nothing to run.
            noteFailedAttempt()
            try? await Task.sleep(for: .milliseconds(failureDelayMilliseconds))
            return .error(401, "This iPhone is no longer paired with the Mac.")
        }
        clearFailedAttempts()
        guard let handler else {
            return .error(503, "The companion is not ready.")
        }
        return await handler(request)
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
    }

    // MARK: - Parsing

    /// Returns nil until a whole request, including its body, has arrived.
    static func parse(_ data: Data) -> (request: Request, headers: [String: String])? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }

        let headText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[range.upperBound...]
        guard body.count >= expected else { return nil }

        return (Request(method: String(requestLine[0]),
                        path: String(requestLine[1]),
                        body: Data(body.prefix(expected))),
                headers)
    }
}
