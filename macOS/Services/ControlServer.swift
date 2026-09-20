import Foundation
import Network

/// A small HTTP server on the local network so the iOS app can steer the
/// simulated location while the Mac holds the developer session open.
///
/// It listens only on the local network, every request must carry the pairing
/// code shown in the companion, and it exposes nothing but the location
/// controls. It is off until switched on.
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

    private(set) var pairingCode = ""
    private(set) var port: UInt16 = 0

    var handler: (@Sendable (Request) async -> Response)?

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

        // Unambiguous characters only: this gets typed on a phone.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        pairingCode = String((0..<8).map { _ in alphabet.randomElement() ?? "A" })

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters,
                                      on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)

        // Announce over Bonjour so the phone can find this Mac by itself.
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Dissappear Companion",
                                              type: Self.serviceType)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let assigned = listener.port?.rawValue {
                self?.port = assigned
            }
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
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
        port = 0
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

    private func respond(to request: Request, headers: [String: String]) async -> Response {
        guard headers["x-pair-code"] == pairingCode else {
            return .error(401, "Wrong pairing code.")
        }
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
