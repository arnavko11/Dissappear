import Foundation
import Network
import Observation

/// Talks to the macOS companion over the local network so the phone can steer
/// the simulated location while the Mac holds the developer session.
///
/// Built on Network.framework rather than URLSession: these are plain local
/// connections, which the URL loading system would refuse without an App
/// Transport Security exception.
@MainActor
@Observable
final class RemoteControlClient {
    struct Status: Equatable {
        var device: String
        var simulating: Bool
        var latitude: Double
        var longitude: Double
        var name: String
        var ready: Bool
        /// Non-empty when the companion's session ended on its own.
        var sessionLost: String
    }

    /// Why the last attempt failed, kept apart so the UI can tell "the Mac is
    /// unreachable" from "the Mac is there and the session died".
    enum Trouble: Equatable {
        case unreachable(String)
        case refused(String)
    }

    struct SavedPlace: Identifiable, Equatable {
        var id: String { "\(name)-\(latitude)-\(longitude)" }
        var name: String
        var latitude: Double
        var longitude: Double
    }

    var host: String {
        didSet { Self.store(host, forKey: "remoteHost") }
    }
    var port: String {
        didSet { Self.store(port, forKey: "remotePort") }
    }
    var pairingCode: String {
        didSet { Self.store(pairingCode, forKey: "remoteCode") }
    }

    private(set) var status: Status?
    private(set) var places: [SavedPlace] = []
    private(set) var lastError: String?
    private(set) var trouble: Trouble?
    private(set) var isBusy = false
    /// Remembered so a lost session can be re-applied in one tap.
    private(set) var lastSent: (latitude: Double, longitude: Double, name: String?)?

    /// Set when a companion was discovered on the network, so no address is
    /// needed. Typed host and port remain as a fallback.
    var discovered: RemoteDiscovery.Companion? {
        didSet { if discovered != nil { lastError = nil } }
    }

    init() {
        host = UserDefaults.standard.string(forKey: "remoteHost") ?? ""
        port = UserDefaults.standard.string(forKey: "remotePort") ?? "8787"
        pairingCode = UserDefaults.standard.string(forKey: "remoteCode") ?? ""
    }

    private static func store(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var isConfigured: Bool {
        guard !pairingCode.isEmpty else { return false }
        return discovered != nil || !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Calls

    func refresh() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let statusPayload = try await send(method: "GET", path: "/status", body: nil)
            status = Status(device: statusPayload["device"] as? String ?? "",
                            simulating: statusPayload["simulating"] as? Bool ?? false,
                            latitude: statusPayload["latitude"] as? Double ?? 0,
                            longitude: statusPayload["longitude"] as? Double ?? 0,
                            name: statusPayload["name"] as? String ?? "",
                            ready: statusPayload["ready"] as? Bool ?? false,
                            sessionLost: statusPayload["sessionLost"] as? String ?? "")

            let placesPayload = try await send(method: "GET", path: "/locations", body: nil)
            places = (placesPayload["locations"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String,
                      let latitude = entry["latitude"] as? Double,
                      let longitude = entry["longitude"] as? Double else { return nil }
                return SavedPlace(name: name, latitude: latitude, longitude: longitude)
            }
            lastError = nil
            trouble = nil
        } catch {
            record(error)
        }
    }

    /// Re-sends the last coordinate, for when the companion lost its session.
    func reapplyLastLocation() async {
        guard let lastSent else { return }
        await setLocation(latitude: lastSent.latitude, longitude: lastSent.longitude, name: lastSent.name)
    }

    private func record(_ error: Error) {
        let message = (error as? RemoteError)?.message ?? error.localizedDescription
        lastError = message
        trouble = (error as? RemoteError)?.isReachability == true ? .unreachable(message) : .refused(message)
    }

    func setLocation(latitude: Double, longitude: Double, name: String?) async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        var payload: [String: Any] = ["latitude": latitude, "longitude": longitude]
        if let name { payload["name"] = name }

        do {
            _ = try await send(method: "POST", path: "/location",
                               body: try JSONSerialization.data(withJSONObject: payload))
            lastError = nil
            trouble = nil
            lastSent = (latitude, longitude, name)
            await refresh()
        } catch {
            record(error)
        }
    }

    func clearLocation() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await send(method: "POST", path: "/clear", body: nil)
            lastError = nil
            trouble = nil
            lastSent = nil
            await refresh()
        } catch {
            record(error)
        }
    }

    // MARK: - Transport

    struct RemoteError: Error {
        var message: String
        /// True when the companion could not be reached at all, as opposed to
        /// reached and refusing.
        var isReachability = false
    }

    private func send(method: String, path: String, body: Data?) async throws -> [String: Any] {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let payload = requestData(method: method, path: path, body: body, host: trimmedHost)

        // A discovered companion is tried first, then the typed address. A
        // Bonjour record can resolve to an interface that cannot actually be
        // reached — a stale advertisement, or an interface the phone has no
        // route to — and the address is right there, so there is no reason to
        // fail without trying it.
        var attempts: [NWEndpoint] = []
        if let discovered { attempts.append(discovered.endpoint) }
        if let direct = directEndpoint(host: trimmedHost) { attempts.append(direct) }

        guard !attempts.isEmpty else {
            throw RemoteError(message: "Pick a companion, or type its address and port.",
                              isReachability: true)
        }

        var lastFailure: Error?
        for endpoint in attempts {
            do {
                return try await parse(await exchange(endpoint: endpoint, payload: payload))
            } catch let failure as RemoteError where failure.isReachability {
                lastFailure = failure          // unreachable: worth trying the next
            }
        }
        throw lastFailure ?? RemoteError(message: "Could not reach the companion.", isReachability: true)
    }

    private func directEndpoint(host trimmedHost: String) -> NWEndpoint? {
        guard !trimmedHost.isEmpty,
              let number = UInt16(port.trimmingCharacters(in: .whitespaces)),
              let endpointPort = NWEndpoint.Port(rawValue: number) else { return nil }
        return .hostPort(host: NWEndpoint.Host(trimmedHost), port: endpointPort)
    }

    private func requestData(method: String, path: String, body: Data?, host trimmedHost: String) -> Data {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(trimmedHost.isEmpty ? "companion" : trimmedHost)\r\n"
        request += "X-Pair-Code: \(pairingCode)\r\n"
        request += "Connection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }
        request += "\r\n"

        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        return payload
    }

    private func parse(_ response: Data) throws -> [String: Any] {
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw RemoteError(message: "The companion sent an unreadable reply.")
        }

        let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let bodyData = response[separator.upperBound...]
        let json = (try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any]) ?? [:]

        guard head.contains(" 200 ") else {
            // A refusal means the companion answered, so it is not a
            // reachability problem and the next endpoint would refuse too.
            throw RemoteError(message: json["error"] as? String ?? "The companion refused the request.")
        }
        return json
    }

    /// How long a single request may take before it is abandoned. Local
    /// network round trips are milliseconds; anything near this is a Mac that
    /// is not answering.
    private static let requestTimeout: Duration = .seconds(8)

    private func exchange(endpoint: NWEndpoint, payload: Data) async throws -> Data {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let finished = Finished()

        return try await withCheckedThrowingContinuation { continuation in
            // Nothing below may hang forever. A connection that is refused or
            // filtered — a firewall on the Mac, the companion switched off,
            // the phone on a different network — settles in `.waiting` and
            // retries there silently for as long as it is allowed to. That is
            // not `.failed`, so the old code never resumed: the request stayed
            // in flight, the spinner never stopped, and Connect stayed
            // disabled with no way back.
            let timeout = Task.detached {
                try? await Task.sleep(for: Self.requestTimeout)
                guard finished.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: RemoteError(
                    message: "The companion did not answer within 8 seconds. Check that it is running, that Remote Control is on, and that macOS is not blocking incoming connections in System Settings ▸ Network ▸ Firewall.",
                    isReachability: true))
            }

            let fail: @Sendable (String) -> Void = { message in
                guard finished.claim() else { return }
                timeout.cancel()
                connection.cancel()
                continuation.resume(throwing: RemoteError(message: message, isReachability: true))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            guard finished.claim() else { return }
                            timeout.cancel()
                            connection.cancel()
                            continuation.resume(throwing: RemoteError(message: error.localizedDescription))
                            return
                        }
                        Self.receiveAll(connection, buffer: Data()) { result in
                            guard finished.claim() else { return }
                            timeout.cancel()
                            connection.cancel()
                            continuation.resume(with: result)
                        }
                    })

                case let .waiting(error):
                    // A refusal is final, whatever Network.framework intends to
                    // do about it; anything vaguer is left to the timeout in
                    // case the interface is still coming up.
                    if Self.isFinal(error) {
                        fail("Could not reach the companion. \(error.localizedDescription)")
                    }

                case let .failed(error):
                    fail("Could not reach the companion. \(error.localizedDescription)")

                case .cancelled:
                    fail("The connection closed.")

                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Errors that will not resolve themselves by waiting.
    private nonisolated static func isFinal(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return code == .ECONNREFUSED || code == .EHOSTUNREACH
            || code == .ENETUNREACH || code == .ETIMEDOUT
    }

    /// Reads until the peer closes, which the companion does after replying.
    ///
    /// Runs on the connection's queue, not the main actor: it is driven by
    /// network callbacks.
    private nonisolated static func receiveAll(_ connection: NWConnection,
                                               buffer: Data,
                                               completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let error {
                completion(.failure(RemoteError(message: error.localizedDescription)))
                return
            }
            if isComplete {
                completion(.success(accumulated))
                return
            }
            receiveAll(connection, buffer: accumulated, completion: completion)
        }
    }

    /// Guards the continuation so it can only be resumed once.
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
